# undo — filet de sécurité pour `rm` et `mv`

Un `rm -rf` de trop, un `mv` qui écrase le mauvais fichier… et c'est perdu.
**undo** remplace `rm` et `mv` dans le terminal : rien n'est supprimé, tout part dans une
corbeille et chaque opération peut être annulée avec une seule commande.

```console
$ rm -rf rapport
✓ rapport → corbeille  (« undo » pour annuler)
$ undo
↩ restauré : /Users/moi/projet/rapport
```

- `rm` / `mv` habituels, mêmes options (`-rfiv`, `-inv`)
- `undo`, `undo 3`, `undo redo` : annuler et refaire comme dans un éditeur
- `undo restore <nom>` pour récupérer un fichier précis, même des jours plus tard
- purge automatique (30 jours, 5 Go max par défaut)
- garde-fous : refuse de toucher `/`, `~`, les dossiers système, les racines de volumes
- un seul fichier Swift, aucune dépendance

macOS uniquement.

## Installation

```sh
git clone https://github.com/bini74/undo.git
cd undo
./install.sh          # compile avec swiftc → ~/.local/bin/undo
```

Puis dans `~/.zshrc` :

```sh
export PATH="$HOME/.local/bin:$PATH"
alias rm="undo rm"
alias mv="undo mv"
```

Il faut les outils de ligne de commande Xcode (`xcode-select --install`) pour `swiftc`.

## Commandes

| Commande | Effet |
|---|---|
| `rm -rf dossier`, `rm a b c` | supprime → corbeille |
| `mv a b c dossier/` | déplace (multi-sources) ; une cible écrasée part en corbeille |
| `undo` / `undo 3` | annule la dernière / les 3 dernières opérations |
| `rm` ou `mv` sans argument | annule le dernier rm / mv |
| `undo redo [n]` | refait ce qui a été annulé |
| `undo list [n]` | historique |
| `undo restore rapport` / `undo restore #2` | restaure par nom ou par entrée de `list` |
| `undo trash` / `undo open` | contenu de la corbeille / l'ouvre dans le Finder |
| `undo purge [--all\|--older-than 30d] [--dry-run]` | purge définitive |
| `undo doctor` | répare journal ↔ corbeille, adopte les orphelins |
| `undo config [init]` | affiche / crée la configuration |

Le vrai `rm`/`mv` reste accessible : `/bin/rm`, `/bin/mv`, ou `\rm`, `\mv`.

## Documentation

Tout le détail est dans le [wiki](https://github.com/bini74/undo/wiki) :
[installation](https://github.com/bini74/undo/wiki/Installation),
[commandes](https://github.com/bini74/undo/wiki/Commandes),
[configuration](https://github.com/bini74/undo/wiki/Configuration),
[fonctionnement](https://github.com/bini74/undo/wiki/Fonctionnement),
[FAQ](https://github.com/bini74/undo/wiki/FAQ).
