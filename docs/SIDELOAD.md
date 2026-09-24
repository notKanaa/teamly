# Installer Équipe sur ton iPhone depuis Windows

Sans compte développeur Apple payant, on ne peut pas publier l'app sur l'App Store ni sur TestFlight. On l'installe donc soi-même (*sideload*) avec **Sideloadly**, un outil gratuit pour Windows, et un **Apple ID gratuit**.

En résumé :
1. la CI GitHub fabrique un fichier `Equipe-unsigned.ipa` (l'app non signée) ;
2. Sideloadly le signe avec ton Apple ID et l'installe sur l'iPhone branché en USB ;
3. l'installation est valable **7 jours**, puis on recommence (1 minute).

## Ce qu'il te faut

- Un PC Windows et un câble USB pour l'iPhone.
- Un iPhone sous **iOS 17 ou plus récent**.
- Un **Apple ID** (celui de ton iPhone, ou un deuxième créé exprès : voir [Sécurité](#sécurité)).
- Un compte GitHub connecté (pour télécharger l'IPA).

## 1. Préparer Windows (une seule fois)

1. **iTunes et iCloud, versions téléchargées depuis apple.com**, pas celles du Microsoft Store : Sideloadly a besoin de leurs composants. La page de téléchargement de Sideloadly donne les bons liens. Si tu as déjà les versions Microsoft Store et que Sideloadly ne voit pas ton iPhone, désinstalle-les puis installe les versions apple.com.
2. **Sideloadly** : télécharge la version Windows sur https://sideloadly.io et installe-la.
3. Branche l'iPhone en USB et déverrouille-le. À la question « Faire confiance à cet ordinateur ? », réponds **Se fier**, puis tape ton code. Ouvre iTunes une fois pour vérifier qu'il voit l'iPhone.

## 2. Télécharger l'IPA

1. Sur GitHub, ouvre le dépôt `notKanaa/teamly` → onglet **Actions** → workflow **CI**.
2. Clique sur le dernier run **vert** de la branche `main`.
3. En bas de la page, section **Artifacts** : télécharge **`Equipe-unsigned-ipa`** (il faut être connecté à GitHub).
4. Décompresse le zip : tu obtiens `Equipe-unsigned.ipa`.

L'artifact est gardé 30 jours. S'il n'y en a plus, ou pour reconstruire l'app (par exemple après avoir changé une variable Supabase) : *Actions → CI → Run workflow* sur `main`, puis attends la fin du run (quelques dizaines de minutes).

L'IPA contient l'adresse de ton projet Supabase ([docs/SUPABASE.md](SUPABASE.md), étape 5). Tous les membres de ton groupe utilisent donc le même serveur.

## 3. Installer avec Sideloadly

1. Ouvre Sideloadly, avec l'iPhone branché et déverrouillé.
2. **iDevice** : choisis ton iPhone.
3. **Apple account** : ton adresse Apple ID.
4. Glisse `Equipe-unsigned.ipa` sur l'icône IPA à gauche.
5. **Advanced options** : ne change **pas** le *Bundle ID*. L'app doit garder celui qui a été choisi dans `APP_BUNDLE_ID`, sinon l'actualisation en arrière-plan ne fonctionne pas et chaque réinstallation crée une nouvelle app.
6. Clique sur **Start**. Sideloadly demande le mot de passe de ton Apple ID, puis éventuellement le code de validation à 6 chiffres envoyé sur tes appareils Apple.
7. Attends le message **Done**.

## 4. Autoriser l'app sur l'iPhone (une seule fois)

1. **Mode développeur** (obligatoire pour les apps installées ainsi) : *Réglages → Confidentialité et sécurité → Mode développeur* (tout en bas de la page) → active-le. L'iPhone redémarre. Après le redémarrage, confirme **Activer** et tape ton code. L'option n'apparaît qu'une fois une app installée par Sideloadly.
2. **Faire confiance à ton Apple ID** : *Réglages → Général → VPN et gestion de l'appareil* → sous « App de développeur », touche ton adresse Apple ID → **Faire confiance à « … »** → confirme.
3. Ouvre **Équipe**. Accepte les notifications si tu veux les rappels (voir [NOTIFICATIONS.md](NOTIFICATIONS.md)).

## 5. Tous les 7 jours : ré-signer

Avec un Apple ID gratuit, la signature expire au bout de **7 jours**. L'app refuse alors de s'ouvrir, mais rien n'est perdu : les données sont sur le serveur, et la session reste enregistrée sur l'iPhone.

Pour la prolonger, refais l'[étape 3](#3-installer-avec-sideloadly) avec le **même Apple ID** et le même fichier (ou une IPA plus récente). L'app est remplacée sur place et tu restes connecté. Autant le faire avant l'expiration, par exemple chaque week-end.

Si ta version de Sideloadly propose l'actualisation automatique (*auto-refresh*, dans les options avancées), elle peut s'en charger. Il faut alors que le PC soit allumé, Sideloadly lancé, et l'iPhone sur le même réseau Wi-Fi.

**Mettre à jour l'app** se fait de la même façon : télécharge la nouvelle IPA de la CI et installe-la par-dessus.

## Limites d'un Apple ID gratuit

| Limite | Conséquence |
|---|---|
| Signature valable 7 jours | Réinstaller chaque semaine (étape 5) |
| 3 apps installées ainsi au maximum par iPhone | Équipe en occupe une |
| 10 identifiants d'app (*App ID*) par semaine | Ne pas changer de Bundle ID à chaque installation |
| Pas de notifications push Apple (APNs) | Rappels locaux + option ntfy à la place ([NOTIFICATIONS.md](NOTIFICATIONS.md)) |
| Pas de TestFlight ni d'App Store | **Chaque membre du groupe** installe l'app lui-même, depuis son ordinateur, avec son propre Apple ID (Sideloadly existe aussi sur Mac) |

Avec le programme Apple Developer (99 $ par an), ces limites disparaissent : distribution par TestFlight, installation valable 90 jours, vraies notifications push. Voir [NOTIFICATIONS.md](NOTIFICATIONS.md#4-plus-tard--les-vraies-notifications-push-apns).

## Sécurité

- Sideloadly est un outil tiers. D'après ses auteurs, il n'envoie ton mot de passe Apple ID **qu'aux serveurs d'Apple**, pour créer le certificat gratuit. Si tu préfères, crée un **Apple ID secondaire** dédié au sideload. Il n'a pas besoin d'être celui de l'iPhone.
- L'IPA vient de la CI de ton dépôt, construite depuis le code public. N'installe pas d'IPA trouvée ailleurs.
- Tu peux désactiver le Mode développeur quand tu n'as plus d'app installée de cette façon.

## Dépannage

| Symptôme | Que faire |
|---|---|
| Sideloadly ne voit pas l'iPhone | Déverrouille-le, rebranche-le, vérifie qu'iTunes le voit, et installe les versions apple.com d'iTunes/iCloud |
| Erreur liée au mot de passe Apple ID | Vérifie qu'il fonctionne sur appleid.apple.com. Avec la double authentification, Sideloadly demande le code |
| « Développeur non approuvé » à l'ouverture | Étape 4.2 : faire confiance à ton Apple ID |
| « Mode développeur requis » | Étape 4.1 |
| L'app s'ouvre puis se ferme aussitôt | La signature a expiré : réinstalle (étape 5) |
| « Configuration manquante » | L'IPA a été construite sans les variables Supabase : voir [SUPABASE.md](SUPABASE.md#5-variables-du-dépôt-github) |
| Limite d'App ID atteinte | Attends 7 jours, et garde toujours le même Bundle ID |
