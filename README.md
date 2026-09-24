# Équipe

**Équipe** est une app iPhone native (SwiftUI) pour organiser les tâches d'un groupe : une coloc, une asso, une équipe de sport, une famille…

- **Comptes** : e-mail + mot de passe, « Mot de passe oublié » avec un code à 6 chiffres reçu par e-mail.
- **Groupes** : on crée un groupe, puis on invite les autres avec un **code de 8 caractères** à partager.
- **Rôles** : les **admins** gèrent le groupe (renommer, inviter, promouvoir, retirer un membre). Les **membres** créent des tâches et font avancer celles qui leur sont assignées.
- **Tâches** : titre, description, **priorité** (basse, moyenne, haute), **échéance**, **statut** (à faire, en cours, terminée). Une tâche peut être assignée à une ou plusieurs personnes du groupe.
- **Mes tâches** : toutes les tâches qui te sont assignées, tous groupes confondus, rangées par échéance (En retard, Aujourd'hui, Cette semaine…), avec un badge « Nouveau ».
- **Notifications** : rappels avant l'échéance, alerte quand on t'assigne une tâche, push optionnel via l'app gratuite ntfy. Détails : [docs/NOTIFICATIONS.md](docs/NOTIFICATIONS.md).
- **Temps réel** : quand quelqu'un modifie une tâche, l'écran des autres membres se met à jour tout seul.
- **Suppression du compte** depuis l'app (il faut taper « SUPPRIMER » pour confirmer).

L'app est en français et fonctionne sur iPhone avec iOS 17 ou plus récent. Tout le projet est **gratuit** : Supabase (offre gratuite), GitHub Actions, et installation sur l'iPhone avec un Apple ID gratuit.

## Captures d'écran

Elles sont prises automatiquement par la CI à chaque push sur `main`, avec des données de démo (branche [`ci-screenshots`](https://github.com/notKanaa/teamly/tree/ci-screenshots)).

| Connexion | Groupes | Créer un groupe |
|:-:|:-:|:-:|
| <img src="https://raw.githubusercontent.com/notKanaa/teamly/ci-screenshots/01-connexion.png" width="230" alt="Écran de connexion"> | <img src="https://raw.githubusercontent.com/notKanaa/teamly/ci-screenshots/02-groupes.png" width="230" alt="Liste des groupes"> | <img src="https://raw.githubusercontent.com/notKanaa/teamly/ci-screenshots/03-creer-groupe.png" width="230" alt="Créer un groupe"> |
| **Code d'invitation** | **Nouvelle tâche** | **Détail du groupe** |
| <img src="https://raw.githubusercontent.com/notKanaa/teamly/ci-screenshots/04-code-invitation.png" width="230" alt="Code d'invitation"> | <img src="https://raw.githubusercontent.com/notKanaa/teamly/ci-screenshots/05-nouvelle-tache.png" width="230" alt="Nouvelle tâche"> | <img src="https://raw.githubusercontent.com/notKanaa/teamly/ci-screenshots/06-detail-groupe.png" width="230" alt="Détail du groupe"> |
| **Mes tâches** | **Membres** | **Réglages** |
| <img src="https://raw.githubusercontent.com/notKanaa/teamly/ci-screenshots/07-mes-taches.png" width="230" alt="Mes tâches"> | <img src="https://raw.githubusercontent.com/notKanaa/teamly/ci-screenshots/08-membres.png" width="230" alt="Membres du groupe"> | <img src="https://raw.githubusercontent.com/notKanaa/teamly/ci-screenshots/09-reglages.png" width="230" alt="Réglages"> |

## Par où commencer

| Je veux… | Guide |
|---|---|
| Configurer le serveur Supabase (réglages Auth, e-mails, variables GitHub) | [docs/SUPABASE.md](docs/SUPABASE.md) |
| Installer l'app sur mon iPhone depuis Windows | [docs/SIDELOAD.md](docs/SIDELOAD.md) |
| Comprendre les notifications (et leurs limites) | [docs/NOTIFICATIONS.md](docs/NOTIFICATIONS.md) |
| Comprendre comment le code est construit et testé | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Connaître les règles exactes (permissions, API, erreurs) | [docs/CONTRACTS.md](docs/CONTRACTS.md) (en anglais) |

## Organisation du dépôt

```
App/                      L'app iOS (SwiftUI) : ne se compile que sur un Mac, donc en CI
  Sources/                  écrans (Features/), navigation, notifications, configuration
  UITests/                  tests UI + les 10 captures d'écran
Packages/TeamTasksKit/    Package Swift : toute la logique, testable sous Linux (Docker)
  Sources/TeamTasksCore       modèles, règles, permissions, ViewModels (sans SwiftUI ni Supabase)
  Sources/TeamTasksMocks      faux serveur en mémoire + données de démo
  Sources/TeamTasksContract   scénarios de contrat joués contre le faux serveur ET contre Supabase
  Sources/TeamTasksSupabase   branchement sur Supabase (Auth, PostgREST, Realtime)
  Tests/                      tests unitaires et d'intégration
supabase/                 Le serveur
  migrations/               schéma SQL, sécurité (RLS), fonctions RPC
  tests/database/           tests pgTAP
  seed.sql                  données de démo (Supabase local uniquement)
  templates/recovery.html   e-mail « code de réinitialisation »
Config/                   Réglages de build (Base.xcconfig ; Secrets.xcconfig est généré)
scripts/                  Outils Node : tests Swift sous Docker, secrets, scripts de CI
project.yml               Description du projet Xcode (XcodeGen génère le .xcodeproj en CI)
.github/workflows/        ci.yml (build + tests) et keepalive.yml (réveil de Supabase)
docs/                     Documentation
```

## Développer en local (Windows)

Pré-requis : **Git**, **Node.js** (LTS) et **Docker Desktop** démarré. Il n'y a pas besoin de Mac : l'app SwiftUI se compile uniquement en CI, mais le serveur et toute la logique Swift tournent et se testent sur Windows, dans Docker.

```powershell
npm install          # installe la CLI Supabase (version fixée dans package.json)
npm run db:start     # démarre Supabase en local dans Docker (le premier lancement est long)
npm run verify       # remet la base à zéro, lance pgTAP, le linter SQL et les tests Swift
```

| Commande | Effet |
|---|---|
| `npm run db:start` / `db:stop` | Démarre / arrête le Supabase local |
| `npm run db:status` | Affiche les adresses et clés locales |
| `npm run db:reset` | Recrée la base : migrations + données de démo (`seed.sql`) |
| `npm run db:test` | Tests pgTAP de la base |
| `npm run db:lint` | Linter SQL (erreurs seulement) |
| `npm run swift:test` | Tests Swift (unitaires) dans le conteneur Linux `swift:6.3-noble` |
| `npm run swift:it` | Tests Swift + intégration contre le Supabase local (il doit tourner) |
| `npm run verify` | `db:reset`, `db:test`, `db:lint` puis `swift:test` |

Quand le Supabase local tourne :
- **Studio** (interface web de la base) : http://127.0.0.1:54323
- **Mailpit** (boîte mail de test, pour voir les codes de réinitialisation) : http://127.0.0.1:54324
- Comptes de démo (local uniquement) : `camille@example.com`, `lucas@example.com`, `ines@example.com`, mot de passe `motdepasse123`.

Bon à savoir :
- Le premier `swift:test` télécharge l'image Swift et compile les dépendances : compte plusieurs minutes. Les suivants sont bien plus rapides (le dossier `.build` est gardé dans un volume Docker).
- En local, la compilation Swift se limite par défaut à 2 tâches en parallèle (variable `SWIFT_JOBS`), pour ne pas saturer la mémoire de Docker sur un PC de 8 Go.
- Une migration déjà envoyée au projet Supabase hébergé ne se modifie plus : tout changement de schéma va dans un **nouveau** fichier de `supabase/migrations/` (voir [docs/SUPABASE.md](docs/SUPABASE.md)).

## Intégration continue (GitHub Actions)

Le workflow [`ci.yml`](.github/workflows/ci.yml) se lance à chaque push sur `main`, sur les pull requests, et à la main (Actions → CI → *Run workflow*). Il a trois jobs :

| Job | Machine | Ce qu'il fait |
|---|---|---|
| **Database (pgTAP)** | Ubuntu | Démarre Postgres avec les migrations, lance le linter SQL et les tests pgTAP |
| **Swift package (Linux + local Supabase)** | Ubuntu | Démarre Supabase, lance tous les tests Swift, dont l'intégration (inscription, code par e-mail, groupes, tâches, temps réel) |
| **iOS app** | macOS (Xcode 26) | Génère le projet Xcode, lance les tests Swift sur macOS, les tests UI sur simulateur, publie les **captures**, puis construit l'**IPA non signée** |

Ce que la CI produit :
- l'artifact **`screenshots`** (14 jours), aussi publié sur la branche publique `ci-screenshots` pour `main` ;
- l'artifact **`Equipe-unsigned-ipa`** (30 jours, sur `main` et en lancement manuel) : c'est le fichier à installer avec Sideloadly ([docs/SIDELOAD.md](docs/SIDELOAD.md)). Il contient l'adresse de ton projet Supabase, lue dans les *Variables* du dépôt ;
- en cas d'échec, les erreurs apparaissent en **annotations** sur la page du run (lisibles sans télécharger les logs).

Le workflow [`keepalive.yml`](.github/workflows/keepalive.yml) appelle le serveur tous les 3 jours pour que le projet Supabase gratuit ne soit pas mis en pause (voir [docs/SUPABASE.md](docs/SUPABASE.md#6-le-keepalive)).

## Statut

Au 24 septembre 2026 :
- **v1 complète** : comptes, groupes, invitations par code, rôles, tâches multi-assignées, Mes tâches, rappels locaux, temps réel, suppression du compte.
- **Tests au vert** : 487 tests pgTAP ; 466 tests Swift sous Linux, dont 56 scénarios de contrat joués contre le Supabase local ; tests UI et 10 captures sur macOS.
- **Serveur hébergé** : projet Supabase gratuit créé, migrations appliquées, variables GitHub renseignées. Restent quelques réglages Auth à vérifier : voir la [checklist](docs/SUPABASE.md#où-en-es-tu).

Limites connues :
- **Quotas d'écriture** : pour protéger la base gratuite (500 Mo), chaque compte peut créer au plus **20 groupes** et **200 tâches** par heure ; au-delà, l'app affiche « Trop de tentatives ».
- **« Mot de passe oublié »** : tant qu'aucun SMTP n'est configuré, Supabase n'envoie l'e-mail qu'aux membres de ton équipe Supabase (voir [docs/SUPABASE.md](docs/SUPABASE.md#4-optionnel-envoyer-les-e-mails-avec-gmail)).
- **Apple ID gratuit** : l'app installée expire au bout de 7 jours et doit être réinstallée ; chaque personne du groupe doit l'installer elle-même depuis un ordinateur (voir [docs/SIDELOAD.md](docs/SIDELOAD.md)).
