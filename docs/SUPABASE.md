# Mettre en place Supabase (serveur hébergé)

Supabase fournit le serveur de l'app : les comptes (Auth), la base de données Postgres, et le temps réel. L'offre gratuite suffit largement pour un groupe d'amis ou une asso.

Ton projet :

| | |
|---|---|
| Nom | `teamly` |
| Référence (*project ref*) | `ihvmlbvkszqtcguliyla` |
| Adresse | https://ihvmlbvkszqtcguliyla.supabase.co |
| Tableau de bord | https://supabase.com/dashboard/project/ihvmlbvkszqtcguliyla |

Le tableau de bord de Supabase est en anglais : les noms de menus sont donnés tels quels ci-dessous (ils peuvent légèrement varier selon les mises à jour).

## Où en es-tu

État au 24 septembre 2026 :

- [x] Projet gratuit créé
- [x] Les 11 migrations sont appliquées (le serveur répond `pong` à `rpc/ping`)
- [x] Réglages Auth appliqués : « Confirm email » désactivé, mot de passe de 8 caractères minimum, code e-mail à 6 chiffres ([étape 3](#3-réglages-auth))
- [x] Variables GitHub `SUPABASE_HOST`, `SUPABASE_PUBLISHABLE_KEY`, `APP_BUNDLE_ID` renseignées
- [ ] *(Optionnel)* SMTP Gmail pour que « Mot de passe oublié » marche pour tout le monde ([étape 4](#4-optionnel-envoyer-les-e-mails-avec-gmail))
- [ ] Modèle d'e-mail « Reset Password » avec le code ([étape 3](#3-réglages-auth)) : sur l'offre gratuite, possible seulement une fois le SMTP Gmail configuré
- [ ] Lancer une fois le keepalive à la main pour vérifier qu'il passe ([étape 6](#6-le-keepalive))

## 1. Créer le projet

*Déjà fait.* Pour mémoire : sur https://supabase.com, *New project*, offre **Free**, une région proche (Europe), et un **mot de passe de base de données** que tu gardes précieusement (il sert à l'étape 2). Supabase accepte 2 projets gratuits actifs par compte.

## 2. Envoyer le schéma de la base (migrations)

*Déjà fait* pour les 11 migrations actuelles. Chaque nouvelle migration s'envoie de la même façon, avec `npx supabase db push`. Dans PowerShell, à la racine du dépôt (`D:\mobileApp\team`) :

```powershell
npx supabase login                                     # ouvre le navigateur pour te connecter
npx supabase link --project-ref ihvmlbvkszqtcguliyla   # demande le mot de passe de la base
npx supabase db push                                   # liste les migrations à appliquer, puis confirme avec Y
npx supabase migration list                            # les colonnes Local et Remote doivent être identiques
```

- `login` et `link` ne sont à faire qu'une fois par ordinateur.
- Mot de passe de la base oublié ? *Project Settings → Database → Reset database password*.
- **N'ajoute jamais `--include-seed`** : `seed.sql` crée des comptes de démo avec un mot de passe public. Il est réservé au Supabase local.
- **N'utilise pas `npx supabase config push`** : `supabase/config.toml` est réglé pour le Supabase local (adresses `127.0.0.1`, limites de test). Les réglages du projet hébergé se font à la main (étape 3).

### La règle d'or : on ne modifie jamais une migration déjà envoyée

Supabase retient quelles migrations il a appliquées. Si on modifie un fichier déjà envoyé, la base hébergée ne verra jamais la modification.

Tout changement de schéma passe donc par un **nouveau** fichier :
1. `npx supabase migration new nom_du_changement` crée `supabase/migrations/<horodatage>_nom_du_changement.sql` (l'horodatage doit être postérieur à `20260924000300`) ;
2. on écrit le SQL et on met à jour les tests ;
3. on vérifie en local avec `npm run verify` ;
4. après le merge sur `main`, on lance `npx supabase db push`.

De même, ne modifie pas les tables à la main dans le *Table Editor* : la base hébergée ne correspondrait plus aux migrations. Consulter les données, en revanche, ne pose aucun problème.

## 3. Réglages Auth

Dans le tableau de bord : **Authentication**.

**Sign In / Providers → Email** (ou *Providers → Email*) :

| Réglage | Valeur | Pourquoi |
|---|---|---|
| Allow new users to sign up | activé | l'inscription se fait depuis l'app |
| Confirm email | **désactivé** *(déjà fait)* | on peut utiliser l'app tout de suite après l'inscription, sans e-mail |
| Minimum password length | **8** *(déjà fait)* | même règle que l'app (8 caractères minimum) |
| Email OTP Length | **6** *(déjà fait)* | l'app attend un code de **6 chiffres** exactement |
| Email OTP Expiration | **3600** secondes | le code est valable une heure, comme l'annonce l'e-mail |

Enregistre (*Save*).

**Emails → Templates → Reset Password** :

> Sur l'offre gratuite, Supabase ne laisse modifier les modèles d'e-mail et *Email OTP Length* qu'une fois un **SMTP personnalisé** configuré. Fais donc d'abord l'[étape 4](#4-optionnel-envoyer-les-e-mails-avec-gmail) (SMTP Gmail avec un mot de passe d'application), puis reviens ici.

- **Subject** : `Équipe — code de réinitialisation`
- **Body** : remplace tout le contenu par celui du fichier [`supabase/templates/recovery.html`](../supabase/templates/recovery.html).

Le modèle doit contenir `{{ .Token }}` : c'est le code à 6 chiffres que l'on tape dans l'app. Le modèle par défaut contient un lien (`{{ .ConfirmationURL }}`), qui ne sert à rien ici, car l'app n'utilise pas de liens.

Rien à régler dans *URL Configuration*, pour la même raison.

## 4. (Optionnel) Envoyer les e-mails avec Gmail

**Pourquoi.** Tant qu'aucun serveur SMTP n'est configuré, le service d'e-mail intégré de Supabase n'envoie qu'aux **membres de ton équipe Supabase** (toi), et seulement quelques e-mails par heure. L'inscription n'envoie aucun e-mail (la confirmation est désactivée). Seul « Mot de passe oublié » est concerné : sans SMTP, il ne fonctionne que pour ton adresse.

**Créer un mot de passe d'application Google** (c'est toi qui le fais, et il ne doit jamais être écrit dans le dépôt) :
1. Sur ton compte Google : *Sécurité* → active la **Validation en deux étapes** si ce n'est pas déjà fait.
2. Ouvre https://myaccount.google.com/apppasswords, crée un mot de passe nommé par exemple « Supabase Équipe ».
3. Google affiche un mot de passe de 16 lettres, **une seule fois** : copie-le.

**Le donner à Supabase** : *Authentication → Emails → SMTP Settings* → active *Enable custom SMTP* :

| Champ | Valeur |
|---|---|
| Sender email | ton adresse Gmail |
| Sender name | `Équipe` |
| Host | `smtp.gmail.com` |
| Port | `465` |
| Username | ton adresse Gmail complète |
| Password | le mot de passe d'application (sans les espaces) |

Enregistre, puis teste « Mot de passe oublié » dans l'app avec l'adresse de quelqu'un d'autre. Les premiers e-mails arrivent parfois dans les spams.

À savoir :
- Gmail limite l'envoi à quelques centaines d'e-mails par jour, ce qui est largement suffisant ici.
- Supabase applique aussi sa propre limite d'envoi, réglable dans *Authentication → Rate Limits*.
- Pour arrêter : désactive *Enable custom SMTP*, et révoque le mot de passe sur la page Google.

## 5. Variables du dépôt GitHub

La CI a besoin de trois valeurs pour construire l'IPA branchée sur ton projet, et le keepalive des deux premières.

Sur GitHub : dépôt `notKanaa/teamly` → **Settings → Secrets and variables → Actions → onglet *Variables*** → *New repository variable*. Ce sont bien des **Variables**, pas des *Secrets* : les workflows lisent `vars.…`.

| Nom | Valeur | Où la trouver |
|---|---|---|
| `SUPABASE_HOST` | `ihvmlbvkszqtcguliyla.supabase.co` | l'adresse du projet, **sans** `https://` ni `/` final |
| `SUPABASE_PUBLISHABLE_KEY` | `sb_publishable_…` (la tienne commence par `sb_publishable_ikvT`) | *Project Settings → API Keys → Publishable key* |
| `APP_BUNDLE_ID` | par ex. `io.github.notkanaa.equipe` | à inventer : unique au monde, en minuscules |

- La clé *publishable* est faite pour être embarquée dans une app : ce sont les règles de sécurité de la base (RLS) qui protègent les données. En revanche, **ne mets jamais** la clé *secret* (`sb_secret_…`), la clé `service_role` ni le mot de passe de la base dans une variable, dans l'app ou dans le dépôt.
- **Ne change plus `APP_BUNDLE_ID`** une fois l'app installée : l'iPhone y verrait une autre app. Il faudrait se reconnecter, et cela consomme un des 10 identifiants d'app autorisés par semaine avec un Apple ID gratuit.
- Après une modification, relance la CI (*Actions → CI → Run workflow*, branche `main`) pour obtenir une nouvelle IPA. Si l'app affiche « Configuration manquante », une de ces valeurs est vide ou mal écrite, et l'écran dit laquelle.

## 6. Le keepalive

Un projet Supabase gratuit est **mis en pause après 7 jours sans activité**. Le workflow [`keepalive.yml`](../.github/workflows/keepalive.yml) appelle `rpc/ping` tous les 3 jours (vers 6 h 17 UTC) pour l'en empêcher.

- **Le tester** : *Actions → Supabase keep-alive → Run workflow*. Le run doit être vert, et son log affiche `"pong"`. S'il dit que les variables ne sont pas définies, reprends l'étape 5.
- **GitHub désactive les workflows planifiés après 60 jours sans commit** sur le dépôt. Tu reçois alors un e-mail de GitHub : il suffit de réactiver le workflow dans l'onglet *Actions*.
- **Si le projet est quand même en pause**, l'app ne peut plus se connecter. Dans le tableau de bord Supabase, clique sur *Restore project* : les données sont conservées. Un projet en pause reste restaurable pendant 90 jours.

## Dépannage

| Symptôme | Cause probable |
|---|---|
| L'app affiche « Configuration manquante » | Variable GitHub vide ou mal écrite (étape 5), puis IPA non reconstruite |
| « Mot de passe oublié » : aucun e-mail | Pas de SMTP et adresse hors de l'équipe Supabase (étape 4), ou e-mail dans les spams |
| L'e-mail reçu contient un lien au lieu d'un code | Modèle « Reset Password » non remplacé (étape 3) |
| Le code reçu a 8 chiffres | *Email OTP Length* n'est pas à 6 (étape 3) |
| Plus rien ne se charge, pour tout le monde | Projet en pause (étape 6) |

Pour voir les comptes créés : *Authentication → Users*. Pour consulter les données : *Table Editor*, en lecture uniquement (voir étape 2).
