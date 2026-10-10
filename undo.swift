// undo — filet de sécurité pour rm/mv
// Remplace le binaire historique /usr/local/bin/undo (source perdue).
// Tout ce qui est supprimé part dans ~/.undo_trash ; journal append-only ~/.undo_log.jsonl.
// Compilation : voir install.sh (swiftc -O).

import Foundation
import Darwin

// MARK: - Sortie / couleurs

let ttyOut = isatty(1) != 0
let ttyErr = isatty(2) != 0
let ttyIn  = isatty(0) != 0

func paint(_ s: String, _ code: String, tty: Bool) -> String {
    tty ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
}
func green(_ s: String)  -> String { paint(s, "32", tty: ttyOut) }
func cyan(_ s: String)   -> String { paint(s, "36", tty: ttyOut) }
func yellow(_ s: String) -> String { paint(s, "33", tty: ttyOut) }
func dim(_ s: String)    -> String { paint(s, "2",  tty: ttyOut) }
func bold(_ s: String)   -> String { paint(s, "1",  tty: ttyOut) }

func out(_ s: String)  { print(s) }
func warn(_ s: String) { FileHandle.standardError.write((paint(s, "33", tty: ttyErr) + "\n").data(using: .utf8)!) }
func fail(_ s: String) { FileHandle.standardError.write((paint(s, "31", tty: ttyErr) + "\n").data(using: .utf8)!) }

var exitStatus: Int32 = 0

// MARK: - Chemins

let home = ProcessInfo.processInfo.environment["UNDO_HOME"] ?? NSHomeDirectory()
let trashDir    = home + "/.undo_trash"
let journalPath = home + "/.undo_log.jsonl"
let oldLogPath  = home + "/.undo_log.json"
let oldLogBak   = home + "/.undo_log.v1.bak.json"
let lockPath    = trashDir + "/.lock"
let purgeMarker = trashDir + "/.last_purge"
let configPath  = home + "/.config/undo/config.json"

let fm = FileManager.default

// MARK: - Config

struct Config {
    var retentionDays: Double = 30
    var maxTrashGB: Double = 5
    var confirmOverFiles: Int = 1000
    var autoPurge: Bool = true

    static func load() -> Config {
        var c = Config()
        guard let data = fm.contents(atPath: configPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return c }
        if let v = obj["retention_days"] as? Double { c.retentionDays = v }
        if let v = obj["retention_days"] as? Int    { c.retentionDays = Double(v) }
        if let v = obj["max_trash_gb"] as? Double   { c.maxTrashGB = v }
        if let v = obj["max_trash_gb"] as? Int      { c.maxTrashGB = Double(v) }
        if let v = obj["confirm_over_files"] as? Int { c.confirmOverFiles = v }
        if let v = obj["auto_purge"] as? Bool        { c.autoPurge = v }
        return c
    }

    func writeDefault() {
        let dir = (configPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let obj: [String: Any] = ["retention_days": retentionDays, "max_trash_gb": maxTrashGB,
                                  "confirm_over_files": confirmOverFiles, "auto_purge": autoPurge]
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            fm.createFile(atPath: configPath, contents: d)
        }
    }
}
let config = Config.load()

// MARK: - Utilitaires fichiers

/// Existence sans suivre les liens symboliques (un lien mort "existe").
func exists(_ p: String) -> Bool {
    var st = stat()
    return lstat(p, &st) == 0
}
func isDirNoFollow(_ p: String) -> Bool {
    var st = stat()
    guard lstat(p, &st) == 0 else { return false }
    return (st.st_mode & S_IFMT) == S_IFDIR
}
/// Répertoire au sens "on peut déplacer dedans" (suit les liens, comme mv).
func isDirFollow(_ p: String) -> Bool {
    var st = stat()
    guard stat(p, &st) == 0 else { return false }
    return (st.st_mode & S_IFMT) == S_IFDIR
}

func absPath(_ p: String) -> String {
    let expanded = (p as NSString).expandingTildeInPath
    let abs = expanded.hasPrefix("/") ? expanded : fm.currentDirectoryPath + "/" + expanded
    return (abs as NSString).standardizingPath
}

func canonical(_ p: String) -> String {
    if let r = realpath(p, nil) { defer { free(r) }; return String(cString: r) }
    // Chemin inexistant : canonicalise le parent
    let parent = (p as NSString).deletingLastPathComponent
    let base = (p as NSString).lastPathComponent
    if let r = realpath(parent, nil) { defer { free(r) }; return String(cString: r) + "/" + base }
    return p
}

func baseName(_ p: String) -> String { (p as NSString).lastPathComponent }

/// Nom unique dans la corbeille : UUID_nomOriginal (tronqué si nécessaire).
func trashPathFor(_ orig: String) -> String {
    var name = baseName(orig)
    if name.count > 200 { name = String(name.suffix(200)) }
    return trashDir + "/" + UUID().uuidString + "_" + name
}

/// Nom libre "x (restauré).ext", "x (restauré 2).ext"…
func freeVariant(_ path: String) -> String {
    if !exists(path) { return path }
    let ns = path as NSString
    let ext = ns.pathExtension
    let stem = ext.isEmpty ? path : ns.deletingPathExtension
    for i in 1...9999 {
        let suffix = i == 1 ? " (restauré)" : " (restauré \(i))"
        let cand = ext.isEmpty ? stem + suffix : stem + suffix + "." + ext
        if !exists(cand) { return cand }
    }
    return path + "." + UUID().uuidString
}

func humanSize(_ bytes: Int64) -> String {
    let units = ["o", "Ko", "Mo", "Go", "To"]
    var v = Double(bytes); var i = 0
    while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
    let s = i == 0 ? String(Int(v)) : String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
    return "\(s) \(units[i])"
}

func sizeOf(_ p: String) -> Int64 {
    var st = stat()
    guard lstat(p, &st) == 0 else { return 0 }
    if (st.st_mode & S_IFMT) != S_IFDIR { return Int64(st.st_size) }
    var total: Int64 = 0
    if let en = fm.enumerator(atPath: p) {
        while let sub = en.nextObject() as? String {
            var s2 = stat()
            if lstat(p + "/" + sub, &s2) == 0, (s2.st_mode & S_IFMT) != S_IFDIR { total += Int64(s2.st_size) }
        }
    }
    return total
}

/// Compte les éléments avec arrêt anticipé (pour le seuil de confirmation).
func quickCount(_ p: String, bail: Int) -> Int {
    guard isDirNoFollow(p) else { return 1 }
    var n = 1
    if let en = fm.enumerator(atPath: p) {
        while en.nextObject() != nil {
            n += 1
            if n > bail { return n }
        }
    }
    return n
}

func relDate(_ ts: Double) -> String {
    let d = Date().timeIntervalSince1970 - ts
    if d < 60 { return "à l'instant" }
    if d < 3600 { return "il y a \(Int(d/60)) min" }
    if d < 86400 { return "il y a \(Int(d/3600)) h" }
    if d < 172800 { return "hier" }
    if d < 30 * 86400 { return "il y a \(Int(d/86400)) j" }
    let f = DateFormatter(); f.dateFormat = "dd/MM/yyyy"
    return f.string(from: Date(timeIntervalSince1970: ts))
}

func ask(_ q: String, def: Bool = false) -> Bool {
    guard ttyIn else { return def }
    print(q + (def ? " [O/n] " : " [o/N] "), terminator: "")
    guard let line = readLine()?.lowercased().trimmingCharacters(in: .whitespaces) else { return def }
    if line.isEmpty { return def }
    return line == "o" || line == "oui" || line == "y" || line == "yes"
}

// MARK: - Verrou (multi-terminaux)

final class FileLock {
    private var fd: Int32 = -1
    init() {
        try? fm.createDirectory(atPath: trashDir, withIntermediateDirectories: true)
        fd = open(lockPath, O_CREAT | O_WRONLY, 0o600)
        guard fd >= 0 else { return }
        var tries = 0
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            tries += 1
            if tries > 50 { warn("undo : verrou occupé, on continue quand même"); break }
            usleep(100_000)
        }
    }
    deinit { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
}

// MARK: - Modèle & journal (event-sourcing JSONL)

enum Kind: String { case rm, mv }

struct Item {
    // rm : orig + trash. mv : from + to (+ overwroteTrash si une cible a été écrasée).
    var orig: String?
    var trash: String?
    var from: String?
    var to: String?
    var overwroteTrash: String?

    var dict: [String: Any] {
        var d: [String: Any] = [:]
        if let v = orig { d["orig"] = v }
        if let v = trash { d["trash"] = v }
        if let v = from { d["from"] = v }
        if let v = to { d["to"] = v }
        if let v = overwroteTrash { d["ow"] = v }
        return d
    }
    static func from(_ d: [String: Any]) -> Item {
        Item(orig: d["orig"] as? String, trash: d["trash"] as? String,
             from: d["from"] as? String, to: d["to"] as? String, overwroteTrash: d["ow"] as? String)
    }
}

struct Op {
    var id: String
    var ts: Double
    var kind: Kind
    var items: [Item]
}

enum ItemStatus { case active, undone, purged }

final class Journal {
    var ops: [Op] = []                       // ordre du journal
    var index: [String: Int] = [:]           // id -> position dans ops
    var status: [String: ItemStatus] = [:]   // "id#idx"
    var undoTs: [String: Double] = [:]       // "id#idx" -> date du dernier undo
    var corruptLines = 0

    static func key(_ id: String, _ i: Int) -> String { "\(id)#\(i)" }

    func load() {
        guard let data = fm.contents(atPath: journalPath),
              let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let e = d["e"] as? String else { corruptLines += 1; continue }
            switch e {
            case "op":
                guard let id = d["id"] as? String, let ts = d["ts"] as? Double,
                      let k = d["kind"] as? String, let kind = Kind(rawValue: k),
                      let rawItems = d["items"] as? [[String: Any]] else { corruptLines += 1; continue }
                let op = Op(id: id, ts: ts, kind: kind, items: rawItems.map(Item.from))
                index[id] = ops.count
                ops.append(op)
                for i in 0..<op.items.count { status[Journal.key(id, i)] = .active }
            case "undo", "redo", "purge":
                guard let id = d["ref"] as? String, let idxs = d["idx"] as? [Int] else { corruptLines += 1; continue }
                let ts = d["ts"] as? Double ?? 0
                for i in idxs {
                    let k = Journal.key(id, i)
                    switch e {
                    case "undo":  status[k] = .undone; undoTs[k] = ts
                    case "redo":  status[k] = .active
                    default:      status[k] = .purged
                    }
                }
            default: corruptLines += 1
            }
        }
    }

    func append(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let fd = open(journalPath, O_CREAT | O_WRONLY | O_APPEND, 0o600)
        guard fd >= 0 else { fail("undo : impossible d'écrire le journal \(journalPath)"); return }
        var line = d; line.append(0x0A)
        line.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }

    func appendOp(_ op: Op) {
        append(["e": "op", "id": op.id, "ts": op.ts, "kind": op.kind.rawValue,
                "items": op.items.map { $0.dict }])
        index[op.id] = ops.count
        ops.append(op)
        for i in 0..<op.items.count { status[Journal.key(op.id, i)] = .active }
    }

    func mark(_ e: String, _ id: String, _ idxs: [Int]) {
        guard !idxs.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        append(["e": e, "ref": id, "idx": idxs, "ts": now])
        for i in idxs {
            let k = Journal.key(id, i)
            switch e {
            case "undo": status[k] = .undone; undoTs[k] = now
            case "redo": status[k] = .active
            default:     status[k] = .purged
            }
        }
    }

    func itemStatus(_ op: Op, _ i: Int) -> ItemStatus { status[Journal.key(op.id, i)] ?? .purged }
    func activeIdxs(_ op: Op) -> [Int] { (0..<op.items.count).filter { itemStatus(op, $0) == .active } }
    func undoneIdxs(_ op: Op) -> [Int] { (0..<op.items.count).filter { itemStatus(op, $0) == .undone } }

    /// Opérations annulables (au moins un item actif), plus récentes en dernier.
    var undoStack: [Op] { ops.filter { !activeIdxs($0).isEmpty } }
    /// Opérations refaisables, triées par undo le plus récent d'abord.
    var redoStack: [Op] {
        ops.filter { !undoneIdxs($0).isEmpty }
           .sorted { a, b in
               let ta = undoneIdxs(a).map { undoTs[Journal.key(a.id, $0)] ?? 0 }.max() ?? 0
               let tb = undoneIdxs(b).map { undoTs[Journal.key(b.id, $0)] ?? 0 }.max() ?? 0
               return ta > tb
           }
    }
    /// Visibles dans `list` : au moins un item non purgé.
    var visible: [Op] { ops.filter { op in (0..<op.items.count).contains { itemStatus(op, $0) != .purged } } }

    /// Réécrit le journal compacté (ops vivantes uniquement, idx renumérotés).
    func compact() {
        var lines: [String] = []
        for op in ops {
            let keep = (0..<op.items.count).filter { itemStatus(op, $0) != .purged }
            guard !keep.isEmpty else { continue }
            let newItems = keep.map { op.items[$0] }
            var obj: [String: Any] = ["e": "op", "id": op.id, "ts": op.ts, "kind": op.kind.rawValue,
                                      "items": newItems.map { $0.dict }]
            guard let d = try? JSONSerialization.data(withJSONObject: obj) else { continue }
            lines.append(String(data: d, encoding: .utf8)!)
            let undone = keep.enumerated().filter { itemStatus(op, $0.element) == .undone }.map { $0.offset }
            if !undone.isEmpty {
                let ts = keep.compactMap { undoTs[Journal.key(op.id, $0)] }.max() ?? op.ts
                obj = ["e": "undo", "ref": op.id, "idx": undone, "ts": ts]
                if let d2 = try? JSONSerialization.data(withJSONObject: obj) {
                    lines.append(String(data: d2, encoding: .utf8)!)
                }
            }
        }
        let tmp = journalPath + ".tmp"
        let body = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        if fm.createFile(atPath: tmp, contents: Data(body.utf8)) {
            try? fm.removeItem(atPath: journalPath)
            try? fm.moveItem(atPath: tmp, toPath: journalPath)
        }
    }
}

// MARK: - Garde-fous

let guardedPaths: Set<String> = ["/", "/Users", "/System", "/Library", "/Applications", "/bin", "/sbin",
                                 "/usr", "/etc", "/var", "/opt", "/private", "/tmp", "/Volumes", "/dev", "/cores",
                                 home, canonical(home)]

/// nil si OK, sinon message d'erreur.
func guardCheck(_ p: String, verb: String) -> String? {
    let real = canonical(p)
    if guardedPaths.contains(real) { return "\(verb) : « \(p) » : refusé (chemin protégé)" }
    if real.hasPrefix("/Volumes/") && real.dropFirst("/Volumes/".count).firstIndex(of: "/") == nil {
        return "\(verb) : « \(p) » : refusé (racine d'un volume)"
    }
    let realTrash = canonical(trashDir)
    if real == realTrash { return "\(verb) : « \(p) » : c'est la corbeille undo (« undo purge --all » pour la vider)" }
    if real.hasPrefix(realTrash + "/") { return "\(verb) : « \(p) » : déjà dans la corbeille (« undo purge » pour vider)" }
    if realTrash.hasPrefix(real + "/") { return "\(verb) : « \(p) » : refusé (contient la corbeille undo)" }
    if real == canonical(fm.currentDirectoryPath) { return "\(verb) : « \(p) » : refusé (répertoire courant)" }
    return nil
}

// MARK: - Déplacements

enum MoveError: Error { case failed(String) }

/// Déplace src -> dst (dst supposé libre). Gère le cross-volume via copie.
func moveItem(_ src: String, _ dst: String) throws {
    let parent = (dst as NSString).deletingLastPathComponent
    if !exists(parent) { try fm.createDirectory(atPath: parent, withIntermediateDirectories: true) }
    do {
        try fm.moveItem(atPath: src, toPath: dst)
    } catch {
        throw MoveError.failed("\(src) → \(dst) : \((error as NSError).localizedDescription)")
    }
}

/// Envoie un chemin dans la corbeille, retourne le chemin corbeille.
func sendToTrash(_ p: String) throws -> String {
    let t = trashPathFor(p)
    try moveItem(p, t)
    return t
}

/// Restaure vers `target` en gérant les conflits. Retourne le chemin final, nil si abandonné.
/// En cas d'écrasement accepté, l'occupant part en corbeille via `journal` (nouvelle op rm).
func restoreTo(_ target: String, from source: String, journal: Journal) -> String? {
    var finalTarget = target
    if exists(target) {
        var choice = "r"
        if ttyIn {
            print(yellow("⚠ « \(target) » existe déjà.") + " [é]craser (l'existant part en corbeille) / [r]enommer / [i]gnorer ? [r] ", terminator: "")
            let line = readLine()?.lowercased().trimmingCharacters(in: .whitespaces) ?? "r"
            choice = line.isEmpty ? "r" : String(line.prefix(1))
        }
        switch choice {
        case "é", "e":
            if let t = try? sendToTrash(target) {
                journal.appendOp(Op(id: UUID().uuidString, ts: Date().timeIntervalSince1970, kind: .rm,
                                    items: [Item(orig: target, trash: t)]))
            } else {
                fail("undo : impossible d'écarter « \(target) »"); return nil
            }
        case "i": return nil
        default: finalTarget = freeVariant(target)
        }
    }
    do {
        try moveItem(source, finalTarget)
        return finalTarget
    } catch {
        fail("undo : échec de restauration \(source) → \(finalTarget)")
        return nil
    }
}

// MARK: - Commande rm

func cmdRm(_ rawArgs: [String], journal: Journal) {
    var recursive = false, force = false, interactive = false, dirOk = false, verbose = false
    var files: [String] = []
    var noMoreFlags = false
    for a in rawArgs {
        if noMoreFlags || a == "-" || !a.hasPrefix("-") { files.append(a); continue }
        switch a {
        case "--": noMoreFlags = true
        case "--recursive": recursive = true
        case "--force": force = true
        case "--interactive": interactive = true
        case "--verbose": verbose = true
        case "--dir": dirOk = true
        default:
            for ch in a.dropFirst() {
                switch ch {
                case "r", "R": recursive = true
                case "f": force = true
                case "i": interactive = true
                case "d": dirOk = true
                case "v": verbose = true
                default:
                    fail("rm : option inconnue « -\(ch) » (le vrai rm reste dispo : /bin/rm)")
                    exitStatus = 64; return
                }
            }
        }
    }
    if files.isEmpty { fail("usage : rm [-rfiv] <fichiers…>"); exitStatus = 64; return }

    // Validation
    var targets: [String] = []
    for f in files {
        let p = absPath(f)
        if !exists(p) {
            if !force { fail("rm : \(f) : fichier ou dossier introuvable"); exitStatus = 1 }
            continue
        }
        if let msg = guardCheck(p, verb: "rm") { fail(msg); exitStatus = 1; continue }
        if isDirNoFollow(p) && !recursive {
            let empty = (try? fm.contentsOfDirectory(atPath: p).isEmpty) ?? false
            if !(dirOk && empty) {
                fail("rm : \(f) : est un répertoire (utilise -r)"); exitStatus = 1; continue
            }
        }
        targets.append(p)
    }
    guard !targets.isEmpty else { return }

    // Confirmation au-delà du seuil (sauf -f)
    if !force && ttyIn {
        var total = 0
        for t in targets {
            total += quickCount(t, bail: config.confirmOverFiles + 1)
            if total > config.confirmOverFiles { break }
        }
        if total > config.confirmOverFiles {
            if !ask(yellow("⚠ plus de \(config.confirmOverFiles) éléments partent en corbeille. Continuer ?")) {
                out(dim("annulé")); return
            }
        }
    }

    var items: [Item] = []
    for t in targets {
        if interactive && !ask("rm : supprimer « \(t) » ?") { continue }
        do {
            let trash = try sendToTrash(t)
            items.append(Item(orig: t, trash: trash))
            if verbose { out(dim("  · \(t)")) }
        } catch MoveError.failed(let msg) {
            fail("rm : \(msg)"); exitStatus = 1
        } catch {
            fail("rm : \(t) : \(error.localizedDescription)"); exitStatus = 1
        }
    }
    guard !items.isEmpty else { return }
    journal.appendOp(Op(id: UUID().uuidString, ts: Date().timeIntervalSince1970, kind: .rm, items: items))

    if items.count == 1 {
        out(green("✓ \(baseName(items[0].orig ?? "")) → corbeille") + dim("  (« undo » pour annuler)"))
    } else {
        out(green("✓ \(items.count) éléments → corbeille") + dim("  (« undo » pour annuler)"))
    }
}

// MARK: - Commande mv

func cmdMv(_ rawArgs: [String], journal: Journal) {
    var interactive = false, noOverwrite = false, verbose = false
    var paths: [String] = []
    var noMoreFlags = false
    for a in rawArgs {
        if noMoreFlags || a == "-" || !a.hasPrefix("-") { paths.append(a); continue }
        switch a {
        case "--": noMoreFlags = true
        case "-f", "--force": break
        case "-i", "--interactive": interactive = true
        case "-n", "--no-clobber": noOverwrite = true
        case "-v", "--verbose": verbose = true
        default:
            fail("mv : option inconnue « \(a) » (le vrai mv reste dispo : /bin/mv)")
            exitStatus = 64; return
        }
    }
    guard paths.count >= 2 else { fail("usage : mv [-inv] <source…> <destination>"); exitStatus = 64; return }

    let dstRaw = paths.removeLast()
    let dst = absPath(dstRaw)
    let dstIsDir = isDirFollow(dst)
    if paths.count > 1 && !dstIsDir {
        fail("mv : \(dstRaw) : n'est pas un répertoire"); exitStatus = 1; return
    }

    var items: [Item] = []
    for srcRaw in paths {
        let src = absPath(srcRaw)
        if !exists(src) { fail("mv : \(srcRaw) : fichier ou dossier introuvable"); exitStatus = 1; continue }
        if let msg = guardCheck(src, verb: "mv") { fail(msg); exitStatus = 1; continue }
        let finalDst = dstIsDir ? dst + "/" + baseName(src) : dst
        if canonical(src) == canonical(finalDst) {
            fail("mv : « \(srcRaw) » et « \(finalDst) » sont identiques"); exitStatus = 1; continue
        }
        var overwroteTrash: String? = nil
        if exists(finalDst) {
            if noOverwrite { continue }
            if isDirNoFollow(finalDst) {
                let empty = (try? fm.contentsOfDirectory(atPath: finalDst).isEmpty) ?? false
                if !empty { fail("mv : \(finalDst) : le répertoire existe et n'est pas vide"); exitStatus = 1; continue }
            }
            if interactive && !ask("mv : écraser « \(finalDst) » ?") { continue }
            // La cible écrasée part en corbeille -> undo la restaurera
            guard let t = try? sendToTrash(finalDst) else {
                fail("mv : impossible d'écarter « \(finalDst) »"); exitStatus = 1; continue
            }
            overwroteTrash = t
        }
        do {
            try moveItem(src, finalDst)
            items.append(Item(from: src, to: finalDst, overwroteTrash: overwroteTrash))
            if verbose { out("\(src) → \(finalDst)") }
        } catch {
            fail("mv : \(srcRaw) : \(error.localizedDescription)"); exitStatus = 1
            // rollback de l'écartement si le move a échoué
            if let t = overwroteTrash { try? moveItem(t, finalDst) }
        }
    }
    guard !items.isEmpty else { return }
    journal.appendOp(Op(id: UUID().uuidString, ts: Date().timeIntervalSince1970, kind: .mv, items: items))
}

// MARK: - Undo / Redo

/// Annule les items donnés d'une op. Retourne les idx effectivement annulés.
func undoOp(_ op: Op, idxs: [Int], journal: Journal) -> [Int] {
    var done: [Int] = []
    for i in idxs.reversed() {
        let item = op.items[i]
        switch op.kind {
        case .rm:
            guard let trash = item.trash, let orig = item.orig else { continue }
            if !exists(trash) {
                warn("undo : « \(baseName(orig)) » n'est plus dans la corbeille (purgé ?)")
                journal.mark("purge", op.id, [i]); continue
            }
            if let final = restoreTo(orig, from: trash, journal: journal) {
                out(cyan("↩ restauré : \(final)"))
                done.append(i)
            }
        case .mv:
            guard let from = item.from, let to = item.to else { continue }
            if !exists(to) {
                warn("undo : « \(to) » n'existe plus, rien à re-déplacer")
                journal.mark("purge", op.id, [i]); continue
            }
            guard let final = restoreTo(from, from: to, journal: journal) else { continue }
            out(cyan("↩ \(to) → \(final)"))
            if let ow = item.overwroteTrash, exists(ow) {
                if let owFinal = restoreTo(to, from: ow, journal: journal) {
                    out(cyan("↩ restauré (écrasé par mv) : \(owFinal)"))
                }
            }
            done.append(i)
        }
    }
    journal.mark("undo", op.id, done)
    return done
}

func redoOp(_ op: Op, journal: Journal) {
    var done: [Int] = []
    for i in journal.undoneIdxs(op) {
        let item = op.items[i]
        switch op.kind {
        case .rm:
            guard let orig = item.orig, let trash = item.trash else { continue }
            guard exists(orig) else { warn("redo : « \(orig) » n'existe plus"); continue }
            if (try? moveItem(orig, trash)) != nil {
                out(green("⟳ \(baseName(orig)) → corbeille"))
                done.append(i)
            } else { fail("redo : échec pour « \(orig) »"); exitStatus = 1 }
        case .mv:
            guard let from = item.from, let to = item.to else { continue }
            guard exists(from) else { warn("redo : « \(from) » n'existe plus"); continue }
            if let ow = item.overwroteTrash, exists(to) {
                if (try? moveItem(to, ow)) == nil { fail("redo : impossible d'écarter « \(to) »"); exitStatus = 1; continue }
            }
            if (try? moveItem(from, to)) != nil {
                out(green("⟳ \(from) → \(to)"))
                done.append(i)
            } else { fail("redo : échec pour « \(from) »"); exitStatus = 1 }
        }
    }
    journal.mark("redo", op.id, done)
}

func cmdUndo(count: Int, kind: Kind?, journal: Journal) {
    var stack = journal.undoStack
    if let k = kind { stack = stack.filter { $0.kind == k } }
    guard !stack.isEmpty else {
        out(dim(kind == nil ? "rien à annuler" : "rien à annuler pour \(kind!.rawValue)"))
        return
    }
    let n = min(count, stack.count)
    if count > stack.count { warn("undo : seulement \(stack.count) opération(s) annulable(s)") }
    for op in stack.suffix(n).reversed() {
        _ = undoOp(op, idxs: journal.activeIdxs(op), journal: journal)
    }
}

func cmdRedo(count: Int, journal: Journal) {
    let stack = journal.redoStack
    guard !stack.isEmpty else { out(dim("rien à refaire")); return }
    for op in stack.prefix(min(count, stack.count)) {
        redoOp(op, journal: journal)
    }
}

// MARK: - list / restore / trash

func opSummary(_ op: Op, journal: Journal) -> String {
    let names = op.items.map { baseName($0.orig ?? $0.from ?? "?") }
    let shown = names.prefix(3).joined(separator: ", ")
    let extra = names.count > 3 ? " +\(names.count - 3)" : ""
    return shown + extra
}

func cmdList(_ n: Int, journal: Journal) {
    let ops = journal.visible.suffix(n).reversed()
    guard !ops.isEmpty else { out(dim("historique vide")); return }
    var i = 1
    for op in ops {
        let active = journal.activeIdxs(op).count
        let undone = journal.undoneIdxs(op).count
        let st: String
        if active > 0 && undone == 0 { st = green("actif") }
        else if active == 0 && undone > 0 { st = cyan("annulé") }
        else if active > 0 { st = yellow("partiel") }
        else { st = dim("purgé") }
        let kindLabel = op.kind == .rm ? "rm" : "mv"
        let num = String(format: "#%-3d", i)
        let date = String(relDate(op.ts).padding(toLength: 14, withPad: " ", startingAt: 0))
        out("\(dim(num)) \(date) \(bold(kindLabel))  \(opSummary(op, journal: journal))  [\(st)]")
        i += 1
    }
    out(dim("→ « undo restore #N » ou « undo restore <nom> » pour restaurer, « undo <n> » pour annuler les n dernières"))
}

func cmdRestore(_ pattern: String, journal: Journal) {
    // #N = index de `undo list`
    if pattern.hasPrefix("#") || Int(pattern) != nil {
        let numStr = pattern.hasPrefix("#") ? String(pattern.dropFirst()) : pattern
        if let n = Int(numStr) {
            let ops = Array(journal.visible.suffix(200).reversed())
            guard n >= 1 && n <= ops.count else { fail("undo : pas d'entrée #\(n) (voir « undo list »)"); exitStatus = 1; return }
            let op = ops[n - 1]
            let idxs = journal.activeIdxs(op)
            guard !idxs.isEmpty else { out(dim("entrée #\(n) : déjà restaurée")); return }
            _ = undoOp(op, idxs: idxs, journal: journal)
            return
        }
    }
    // Motif sur le nom de fichier (items rm actifs uniquement)
    struct Cand { let op: Op; let idx: Int; let orig: String; let trash: String }
    var cands: [Cand] = []
    for op in journal.ops where op.kind == .rm {
        for i in journal.activeIdxs(op) {
            guard let orig = op.items[i].orig, let trash = op.items[i].trash else { continue }
            let name = baseName(orig)
            let matched: Bool
            if pattern.contains("*") || pattern.contains("?") || pattern.contains("[") {
                matched = fnmatch(pattern, name, 0) == 0
            } else {
                matched = name.lowercased().contains(pattern.lowercased())
            }
            if matched { cands.append(Cand(op: op, idx: i, orig: orig, trash: trash)) }
        }
    }
    if cands.isEmpty { out(dim("aucun fichier en corbeille ne correspond à « \(pattern) »")); return }
    if cands.count == 1 {
        let c = cands[0]
        _ = undoOp(c.op, idxs: [c.idx], journal: journal)
        return
    }
    out(bold("\(cands.count) correspondances :"))
    for (i, c) in cands.enumerated().reversed() {
        out("  \(dim(String(format: "%2d.", i + 1))) \(baseName(c.orig))  \(dim("← " + (c.orig as NSString).deletingLastPathComponent + "  · " + relDate(c.op.ts)))")
    }
    guard ttyIn else { fail("undo : précise (motif plus strict), ou utilise « undo restore #N »"); exitStatus = 1; return }
    print("lequel ? [1-\(cands.count), t = tous, rien = annuler] ", terminator: "")
    guard let line = readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { out(dim("annulé")); return }
    if line.lowercased() == "t" || line.lowercased() == "tous" {
        for c in cands { _ = undoOp(c.op, idxs: [c.idx], journal: journal) }
    } else if let n = Int(line), n >= 1 && n <= cands.count {
        let c = cands[n - 1]
        _ = undoOp(c.op, idxs: [c.idx], journal: journal)
    } else { out(dim("annulé")) }
}

func trashContents() -> [String] {
    ((try? fm.contentsOfDirectory(atPath: trashDir)) ?? []).filter { !$0.hasPrefix(".") }
}

func cmdTrash(journal: Journal) {
    let files = trashContents()
    guard !files.isEmpty else { out(dim("corbeille vide (\(trashDir))")); return }
    // trashPath -> (orig, ts)
    var known: [String: (String, Double)] = [:]
    for op in journal.ops {
        for i in 0..<op.items.count where journal.itemStatus(op, i) == .active {
            let it = op.items[i]
            if let t = it.trash, let o = it.orig { known[baseName(t)] = (o, op.ts) }
            if let ow = it.overwroteTrash, let to = it.to { known[baseName(ow)] = (to + " (écrasé par mv)", op.ts) }
        }
    }
    var total: Int64 = 0
    var orphans: [String] = []
    var lines: [(Double, String)] = []
    for f in files {
        let full = trashDir + "/" + f
        let size = sizeOf(full)
        total += size
        if let (orig, ts) = known[f] {
            lines.append((ts, "  \(baseName(orig))  \(dim("← " + (orig as NSString).deletingLastPathComponent))  \(dim(humanSize(size) + " · " + relDate(ts)))"))
        } else {
            orphans.append(f)
        }
    }
    for (_, l) in lines.sorted(by: { $0.0 > $1.0 }) { out(l) }
    if !orphans.isEmpty {
        out(yellow("  + \(orphans.count) fichier(s) orphelin(s) non référencés (« undo doctor » pour les adopter)"))
    }
    out(bold("total : \(files.count) élément(s), \(humanSize(total))") +
        dim("  · rétention \(Int(config.retentionDays)) j, plafond \(String(format: "%.0f", config.maxTrashGB)) Go · « undo purge » pour nettoyer"))
}

// MARK: - purge

/// Purge définitive des items rm actifs plus vieux que cutoff (+ retire les ops mv trop vieilles).
/// Retourne (nb items, octets libérés).
@discardableResult
func purge(olderThan cutoff: Double, journal: Journal, includeAll: Bool = false, dryRun: Bool = false) -> (Int, Int64) {
    var count = 0
    var bytes: Int64 = 0
    for op in journal.ops {
        guard includeAll || op.ts < cutoff else { continue }
        var purged: [Int] = []
        for i in 0..<op.items.count {
            let st = journal.itemStatus(op, i)
            guard st != .purged else { continue }
            let item = op.items[i]
            if st == .active, let t = item.trash, exists(t) {
                bytes += sizeOf(t)
                if !dryRun { try? fm.removeItem(atPath: t) }
                count += 1
            }
            if st == .active, let ow = item.overwroteTrash, exists(ow) {
                bytes += sizeOf(ow)
                if !dryRun { try? fm.removeItem(atPath: ow) }
                count += 1
            }
            purged.append(i)
        }
        if !dryRun && !purged.isEmpty { journal.mark("purge", op.id, purged) }
    }
    return (count, bytes)
}

func parseAge(_ s: String) -> Double? {
    let lower = s.lowercased()
    let num = lower.prefix { $0.isNumber || $0 == "." }
    guard let v = Double(num) else { return nil }
    let unit = lower.dropFirst(num.count)
    switch unit {
    case "d", "j", "": return v * 86400
    case "h": return v * 3600
    case "min", "m": return v * 60
    default: return nil
    }
}

func cmdPurge(_ args: [String], journal: Journal) {
    var all = false, dry = false, yes = false
    var age: Double? = nil
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--all": all = true
        case "--dry-run": dry = true
        case "--yes", "-y": yes = true
        case "--older-than":
            i += 1
            guard i < args.count, let a = parseAge(args[i]) else { fail("undo purge : --older-than 30d|12h|45min"); exitStatus = 64; return }
            age = a
        default: fail("usage : undo purge [--all | --older-than 30d] [--dry-run] [--yes]"); exitStatus = 64; return
        }
        i += 1
    }
    let now = Date().timeIntervalSince1970
    let cutoff = all ? now + 1 : now - (age ?? config.retentionDays * 86400)
    if all && !dry && !yes {
        if !ask(yellow("⚠ vider toute la corbeille (suppression DÉFINITIVE) ?")) { out(dim("annulé")); return }
    }
    let (count, bytes) = purge(olderThan: cutoff, journal: journal, includeAll: all, dryRun: dry)
    if dry {
        out("purge simulée : \(count) élément(s), \(humanSize(bytes)) seraient libérés")
    } else if count == 0 {
        out(dim("rien à purger"))
        journal.compact()
    } else {
        out("⌫ \(count) élément(s) purgés définitivement, \(humanSize(bytes)) libérés")
        journal.compact()
    }
}

/// Purge automatique (throttlée à 1×/heure) : rétention + plafond de taille.
func autoPurge(journal: Journal) {
    guard config.autoPurge else { return }
    var st = stat()
    if lstat(purgeMarker, &st) == 0 {
        let age = Date().timeIntervalSince1970 - Double(st.st_mtimespec.tv_sec)
        if age < 3600 { return }
    }
    fm.createFile(atPath: purgeMarker, contents: Data())
    let cutoff = Date().timeIntervalSince1970 - config.retentionDays * 86400
    let (count, bytes) = purge(olderThan: cutoff, journal: journal)
    if count > 0 {
        out(dim("⌫ purge auto : \(count) élément(s) de plus de \(Int(config.retentionDays)) j supprimés (\(humanSize(bytes)))"))
    }
    // Plafond de taille : purge les plus anciens jusqu'à repasser sous la barre
    let cap = Int64(config.maxTrashGB * 1_000_000_000)
    var total: Int64 = 0
    for f in trashContents() { total += sizeOf(trashDir + "/" + f) }
    if total > cap {
        var freed: Int64 = 0
        for op in journal.ops {  // du plus ancien au plus récent
            guard total - freed > cap else { break }
            var purged: [Int] = []
            for i in journal.activeIdxs(op) {
                let item = op.items[i]
                for t in [item.trash, item.overwroteTrash].compactMap({ $0 }) where exists(t) {
                    freed += sizeOf(t)
                    try? fm.removeItem(atPath: t)
                }
                purged.append(i)
            }
            if !purged.isEmpty { journal.mark("purge", op.id, purged) }
        }
        if freed > 0 {
            out(dim("⌫ corbeille > \(String(format: "%.0f", config.maxTrashGB)) Go : \(humanSize(freed)) libérés (plus anciens d'abord)"))
        }
    }
    if journal.ops.count > 4000 { journal.compact() }
}

// MARK: - doctor

func cmdDoctor(journal: Journal) {
    var fixed = 0
    if journal.corruptLines > 0 {
        out(yellow("⚠ \(journal.corruptLines) ligne(s) illisibles dans le journal (seront éliminées au compactage)"))
        fixed += journal.corruptLines
    }
    // Items actifs dont le fichier corbeille a disparu
    var dead = 0
    for op in journal.ops {
        var gone: [Int] = []
        for i in journal.activeIdxs(op) {
            let item = op.items[i]
            if op.kind == .rm, let t = item.trash, !exists(t) { gone.append(i); dead += 1 }
        }
        if !gone.isEmpty { journal.mark("purge", op.id, gone) }
    }
    if dead > 0 { out("• \(dead) entrée(s) mortes retirées (fichier corbeille disparu)"); fixed += dead }

    // Fichiers de la corbeille non référencés -> adoption
    var referenced = Set<String>()
    for op in journal.ops {
        for i in 0..<op.items.count where journal.itemStatus(op, i) != .purged {
            if let t = op.items[i].trash { referenced.insert(baseName(t)) }
            if let ow = op.items[i].overwroteTrash { referenced.insert(baseName(ow)) }
        }
    }
    var adopted = 0
    for f in trashContents() where !referenced.contains(f) {
        // retire le préfixe UUID_ s'il existe
        var name = f
        if f.count > 37, f[f.index(f.startIndex, offsetBy: 36)] == "_",
           UUID(uuidString: String(f.prefix(36))) != nil {
            name = String(f.dropFirst(37))
        }
        let orig = home + "/undo_restauré/" + name
        journal.appendOp(Op(id: UUID().uuidString, ts: Date().timeIntervalSince1970, kind: .rm,
                            items: [Item(orig: orig, trash: trashDir + "/" + f)]))
        adopted += 1
    }
    if adopted > 0 { out("• \(adopted) fichier(s) orphelin(s) adoptés (restauration → ~/undo_restauré/)"); fixed += adopted }

    // Ancien journal v1 réapparu = l'ancien binaire tourne encore
    if exists(oldLogPath) {
        out(yellow("⚠ \(oldLogPath) existe : l'ancien binaire /usr/local/bin/undo semble encore utilisé (vérifie « which undo »)"))
    }
    journal.compact()
    out(fixed == 0 ? green("✓ tout est cohérent (journal compacté)") : green("✓ doctor terminé, journal compacté"))
}

// MARK: - Migration depuis l'ancien format (.undo_log.json, tableau unique)

func migrateIfNeeded() {
    guard !exists(journalPath), exists(oldLogPath) else { return }
    guard let data = fm.contents(atPath: oldLogPath),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        warn("undo : ancien journal illisible, il est conservé tel quel (\(oldLogPath))")
        return
    }
    var kept = 0, dropped = 0
    var ops: [Op] = []
    for e in arr {
        guard let cmd = e["command"] as? String,
              let origP = e["originalPath"] as? String,
              let newP = e["newPath"] as? String else { dropped += 1; continue }
        var ts = e["timestamp"] as? Double ?? 0
        if ts < 1_000_000_000 { ts += 978_307_200 }  // epoch Cocoa (2001) -> Unix
        let id = (e["id"] as? String) ?? UUID().uuidString
        switch cmd {
        case "rm":
            guard exists(newP) else { dropped += 1; continue }
            ops.append(Op(id: id, ts: ts, kind: .rm, items: [Item(orig: origP, trash: newP)]))
            kept += 1
        case "mv":
            guard exists(newP) else { dropped += 1; continue }
            ops.append(Op(id: id, ts: ts, kind: .mv, items: [Item(from: origP, to: newP)]))
            kept += 1
        default: dropped += 1
        }
    }
    ops.sort { $0.ts < $1.ts }
    let j = Journal()
    for op in ops { j.appendOp(op) }
    try? fm.copyItem(atPath: oldLogPath, toPath: oldLogBak)
    try? fm.removeItem(atPath: oldLogPath)
    out(dim("⇅ migration : \(kept) entrée(s) reprises, \(dropped) mortes ignorées · ancien journal sauvegardé → \(oldLogBak)"))
}

// MARK: - config / help

func cmdConfig(_ args: [String]) {
    if args.first == "init" {
        config.writeDefault()
        out(green("✓ config écrite : \(configPath)"))
        return
    }
    out(bold("config") + dim("  (\(exists(configPath) ? configPath : "défauts — « undo config init » pour créer le fichier"))"))
    out("  retention_days     = \(Int(config.retentionDays))   " + dim("purge auto des éléments plus vieux"))
    out("  max_trash_gb       = \(String(format: "%.1f", config.maxTrashGB))   " + dim("plafond de taille de la corbeille"))
    out("  confirm_over_files = \(config.confirmOverFiles)  " + dim("confirmation au-delà (sans -f)"))
    out("  auto_purge         = \(config.autoPurge)")
}

func cmdHelp() {
    let h = """
    \(bold("undo")) — filet de sécurité pour rm/mv (tout part dans ~/.undo_trash, rien n'est perdu)

    \(bold("via les alias du shell"))
      rm [-rfiv] <fichiers…>      supprime → corbeille
      mv [-inv] <src…> <dst>      déplace (multi-sources OK, cible écrasée sauvegardée)
      rm | mv  (sans argument)    annule le dernier rm / mv

    \(bold("annuler / refaire"))
      undo                        annule la dernière opération
      undo <n>                    annule les n dernières
      undo redo [n]               refait ce qui a été annulé

    \(bold("corbeille"))
      undo list [n]               historique (défaut : 15)
      undo restore <motif|#N>     restaure par nom de fichier ou entrée de list
      undo trash                  contenu + taille de la corbeille
      undo open                   ouvre la corbeille dans le Finder
      undo purge [--all|--older-than 30d] [--dry-run]
                                  purge définitive (défaut : rétention config)

    \(bold("maintenance"))
      undo doctor                 répare journal ↔ corbeille, adopte les orphelins
      undo config [init]          affiche / crée la config (~/.config/undo/config.json)

    purge auto : éléments > \(Int(config.retentionDays)) j ou corbeille > \(String(format: "%.0f", config.maxTrashGB)) Go (config modifiable)
    le vrai rm/mv reste accessible : /bin/rm, /bin/mv (ou \\rm, \\mv)
    """
    out(h)
}

// MARK: - main

@main
struct Undo {
    static func main() {
        try? fm.createDirectory(atPath: trashDir, withIntermediateDirectories: true)
        var args = Array(CommandLine.arguments.dropFirst())

        // Commandes sans verrou ni journal
        switch args.first {
        case "help", "-h", "--help":
            cmdHelp(); return
        case "version", "--version":
            out("undo 2.0 (réécriture Swift, journal JSONL)"); return
        case "open":
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = [trashDir]
            try? p.run(); return
        case "config":
            cmdConfig(Array(args.dropFirst())); return
        default: break
        }

        let lock = FileLock()
        migrateIfNeeded()
        let journal = Journal()
        journal.load()

        var didMutate = true
        switch args.first {
        case nil:
            cmdUndo(count: 1, kind: nil, journal: journal)
        case "rm":
            args.removeFirst()
            if args.isEmpty { cmdUndo(count: 1, kind: .rm, journal: journal) }
            else { cmdRm(args, journal: journal) }
        case "mv":
            args.removeFirst()
            if args.isEmpty { cmdUndo(count: 1, kind: .mv, journal: journal) }
            else { cmdMv(args, journal: journal) }
        case "redo":
            let n = args.count > 1 ? (Int(args[1]) ?? 1) : 1
            cmdRedo(count: n, journal: journal)
        case "list", "ls":
            didMutate = false
            let n = args.count > 1 ? (Int(args[1]) ?? 15) : 15
            cmdList(n, journal: journal)
        case "restore":
            guard args.count > 1 else { fail("usage : undo restore <motif|#N>"); exitStatus = 64; break }
            cmdRestore(args[1], journal: journal)
        case "trash":
            didMutate = false
            cmdTrash(journal: journal)
        case "purge":
            cmdPurge(Array(args.dropFirst()), journal: journal)
        case "doctor":
            cmdDoctor(journal: journal)
        default:
            if let n = Int(args[0]), n > 0 {
                cmdUndo(count: n, kind: nil, journal: journal)
            } else {
                fail("undo : commande inconnue « \(args[0]) » (« undo help »)")
                exitStatus = 64
                didMutate = false
            }
        }

        if didMutate { autoPurge(journal: journal) }
        _ = lock  // garde le verrou jusqu'ici
        exit(exitStatus)
    }
}
