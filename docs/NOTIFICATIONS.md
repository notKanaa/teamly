# Notifications

Les vraies notifications push d'Apple (APNs) exigent le programme Apple Developer, à 99 $ par an. Équipe s'en passe donc et combine trois mécanismes gratuits :

| Mécanisme | Quand ça marche | À activer |
|---|---|---|
| **Rappels d'échéance** (notifications locales) | Toujours, même app fermée, une fois programmés | Autoriser les notifications |
| **« Nouvelle tâche assignée »** (notifications locales) | App ouverte : tout de suite. Sinon : à la prochaine ouverture ou actualisation en arrière-plan | Autoriser les notifications |
| **Push ntfy** (optionnel) | Même app fermée, quelques secondes après l'assignation | Réglages de l'app + app ntfy |

Toucher une notification ouvre directement la tâche concernée, ou « Mes tâches » pour une notification qui en résume plusieurs.

## 1. Notifications locales

Elles sont programmées **par l'iPhone lui-même** : aucun serveur n'est nécessaire pour les afficher. Au premier lancement connecté, l'app demande l'autorisation. Pour changer d'avis plus tard : *Réglages de l'iPhone → Notifications → Équipe*. L'onglet **Réglages** de l'app affiche l'état actuel.

### Rappels d'échéance

- Concernent les tâches **qui te sont assignées**, **non terminées** et **avec une échéance**.
- Le délai se règle dans *Réglages → Rappels d'échéance* : à l'heure de l'échéance, 15 minutes avant, **1 heure avant** (par défaut), 1 jour avant, ou aucun rappel.
- iOS limite à 64 le nombre de notifications en attente par app. Équipe en programme **au plus 60**, pour les échéances les plus proches, et complète la liste au fur et à mesure.
- La liste est remise à jour quand l'app s'ouvre, revient au premier plan, recharge « Mes tâches », ou profite d'une actualisation en arrière-plan. Une tâche assignée pendant que ton app est fermée n'aura donc son rappel qu'après l'une de ces occasions.
- Une fois programmé, un rappel sonne même si l'app est fermée ou si le téléphone est hors ligne.
- Se déconnecter supprime tous les rappels de cet iPhone.

### « Nouvelle tâche assignée »

- **App ouverte** : le serveur signale l'assignation en temps réel, et une bannière s'affiche aussitôt.
- **App fermée ou en arrière-plan** : à la prochaine ouverture (ou actualisation en arrière-plan), l'app demande au serveur les assignations reçues depuis la dernière fois, et les notifie.
- Jusqu'à 5 nouvelles tâches, chacune a sa notification (« titre — groupe »). Au-delà, une seule notification résume : « N nouvelles tâches assignées ».
- Une même assignation n'est jamais notifiée deux fois, et les tâches que tu t'assignes toi-même ne le sont pas.
- Dans l'onglet **Mes tâches**, les tâches assignées depuis ta dernière visite portent un badge « Nouveau ».

## 2. Actualisation en arrière-plan (Background App Refresh)

L'app demande à iOS de la réveiller de temps en temps (au plus toutes les 30 minutes) pour rattraper les assignations et mettre à jour les rappels. C'est gratuit et ne demande aucun droit particulier, mais **c'est iOS qui décide** quand l'app est réveillée : parfois plusieurs fois par jour, parfois jamais.

Pour lui donner toutes ses chances :
- *Réglages → Général → Actualisation en arrière-plan* : active-la, et vérifie qu'elle est activée pour Équipe ;
- évite de **fermer l'app de force** (balayer vers le haut dans le sélecteur d'apps) : iOS ne réveille plus une app fermée ainsi ;
- le mode Économie d'énergie suspend l'actualisation en arrière-plan.

Comme ce n'est pas fiable, les rappels sont programmés à l'avance, et l'option ntfy existe pour les assignations.

## 3. Push optionnel via ntfy

[ntfy](https://ntfy.sh) est un service de notifications gratuit et open source, avec une app iPhone gratuite. L'idée : le serveur Supabase envoie un message à ntfy, qui le pousse sur ton iPhone, **même si Équipe est fermée**.

### L'activer

1. Dans Équipe : *Réglages → Notifications push (ntfy) → Activer les notifications push*. L'app crée un **sujet privé** au nom aléatoire (`equipe-` suivi de 24 caractères).
2. Installe l'app **ntfy** depuis l'App Store. Le bouton « Installer ntfy (App Store) » y mène directement.
3. Dans ntfy, touche **+** et abonne-toi au sujet affiché par Équipe, sur le serveur `ntfy.sh`. Le bouton « Ouvrir dans ntfy » le fait pour toi.

Ensuite, quand **quelqu'un d'autre** t'assigne une tâche, tu reçois « Nouvelle tâche assignée dans « nom du groupe » ». Toucher la notification ouvre Équipe sur la tâche (lien `equipe://task/…`).

Pour éviter les abus, tu reçois **au plus 1 push par tâche** et **au plus 30 push par heure** : au-delà, les assignations restent signalées par les notifications locales.

### Vie privée

- **Seul le nom du groupe est envoyé**, jamais le titre ni le contenu de la tâche.
- ntfy.sh est un serveur public : **toute personne qui connaît ton sujet** peut lire ces messages, et donc savoir quand une tâche t'est assignée et dans quel groupe. Garde-le pour toi, comme un mot de passe.
- Le nom aléatoire du sujet est impossible à deviner. S'il a fuité, désactive puis réactive l'option : l'ancien sujet est supprimé, un nouveau est créé, et il faudra t'y réabonner dans ntfy.
- Désactiver l'option supprime ton sujet du serveur Équipe : plus rien n'y est envoyé.

### Pour les développeurs

- Table `push_subscriptions` (un sujet par utilisateur, lisible par lui seul), RPC `enable_push()` et `disable_push()` : migration `20260923000800`.
- Envoi : migration `20260924000100_ntfy_push.sql`. Le trigger `AFTER INSERT` sur `task_assignees` (`private.notify_assignment_push`) agit pour chaque ligne où `assigned_by` est différent de `user_id`, si l'assigné a un sujet. Il met en file, avec l'extension `pg_net` et dans la transaction de l'assignation, un `POST` JSON vers la racine du serveur ntfy (`private.settings.ntfy_base_url`, `https://ntfy.sh/` par défaut) : `{"topic": "<sujet>", "title": "Équipe", "message": "Nouvelle tâche assignée dans « <groupe> »", "click": "equipe://task/<groupId>/<taskId>"}`. Le sujet ne figure donc jamais dans l'URL. C'est le contrat de [CONTRACTS.md §7](CONTRACTS.md#7-notifications).
- Limites (table `private.push_log`) : au plus 1 push par utilisateur et par tâche, et au plus 30 push par utilisateur, sur une heure glissante (réglage `push_max_per_hour`).
- Une erreur de préparation (pg_net absent, réglage invalide…) devient un simple avertissement : elle ne fait jamais échouer l'assignation. Les erreurs HTTP surviennent plus tard, dans le worker pg_net.
- `ntfy_base_url` à `NULL` (ou vide) coupe l'envoi : c'est le cas de la pile locale et de la CI (`supabase/seed.sql`). Côté tests, pgTAP (`10_ntfy_push.test.sql`) vérifie la requête mise en file dans `net.http_request_queue` et les limites.
- L'envoi part de la base, jamais du téléphone : l'app n'a besoin d'aucune clé ntfy.

## 4. Plus tard : les vraies notifications push (APNs)

Si tu souscris un jour au **programme Apple Developer** (99 $ par an), voici le chemin :

1. **Compte Apple** : sur developer.apple.com, déclare l'identifiant de l'app (`APP_BUNDLE_ID`) avec la capacité *Push Notifications*, et crée une **clé APNs** (fichier `.p8`, avec son *Key ID* et ton *Team ID*).
2. **App** : ajoute un fichier d'entitlements avec `aps-environment` dans `project.yml`, et, dans `AppDelegate`, demande un *device token* (`registerForRemoteNotifications`). Attention : une app qui a ce droit ne s'installe plus avec un Apple ID gratuit.
3. **Base** : dans une nouvelle migration, crée une table `device_tokens` (utilisateur, token), avec ses RPC d'enregistrement et de suppression, sur le modèle de `push_subscriptions`.
4. **Envoi** : une **Edge Function** Supabase signe un jeton avec la clé `.p8` (stockée dans les *secrets* Supabase, jamais dans le dépôt) et appelle l'API APNs d'Apple. Elle est déclenchée sur `INSERT` dans `task_assignees`, par un *Database Webhook* ou par le même trigger `pg_net` que ntfy. Le message peut rester minimal (nom du groupe) ou inclure le titre, puisqu'il ne transite plus par un serveur public.
5. **Distribution** : signer en CI (certificat et profil, par exemple avec une clé d'API App Store Connect) et publier sur **TestFlight**. Fini la réinstallation tous les 7 jours, et les membres du groupe installent l'app en un clic.

Les notifications locales (rappels, rattrapage) restent utiles telles quelles. ntfy peut être gardé en option ou retiré.
