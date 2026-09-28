// Accessibility identifiers of the v3 social features (docs/CONTRACTS-V3.md): « Relancer », « Mode absent »,
// « Échanger mon tour », « Bravo », the comments and the photos. Compiled into the app and the UI test target: plain
// strings only, no imports.

extension AccessibilityID {
    enum Social {
        /// The confirmation shown for a few seconds (« Relance envoyée à Inès »); its label is the message.
        static let toast = "social.toast"

        // Relancer
        /// « Relancer Inès » of the task screen.
        static let nudgeButton = "social.nudge"
        /// « Relancer Inès » in the long-press menu of a task card of the group screen, by task title.
        static func nudgeMenuItem(_ title: String) -> String { "social.nudge.\(title)" }

        // Échanger mon tour
        /// « Proposer mon tour à… » (a menu) of the task screen.
        static let proposeSwapMenu = "social.swap.propose"
        /// A member of that menu, by short name.
        static func proposeSwapOption(_ name: String) -> String { "social.swap.propose.\(name)" }
        /// « En attente de la réponse de Lucas » and its « Annuler ».
        static let outgoingSwap = "social.swap.outgoing"
        static let cancelSwapButton = "social.swap.cancel"
        /// The proposals made to the user (« Mes tâches », the group screen).
        static let swapRequests = "social.swap.requests"
        /// A proposal made to the user, and its buttons, by task title (empty on the task's own screen).
        static func swapRequest(_ title: String) -> String { "social.swap.request.\(title)" }
        static func acceptSwap(_ title: String) -> String { "social.swap.accept.\(title)" }
        static func declineSwap(_ title: String) -> String { "social.swap.decline.\(title)" }

        // Bravo
        /// A reaction chip of the feed (value « 2 réactions, dont la tienne »), by the event's task title and the
        /// emoji's French name (`ReactionEmoji.label`).
        static func reactionChip(_ title: String, _ emojiLabel: String) -> String { "social.reaction.\(title).\(emojiLabel)" }

        // Commentaires
        static let comments = "social.comments"
        /// A comment (its label: the author, the time and the text).
        static let comment = "social.comment"
        static let commentField = "social.comments.field"
        static let commentSendButton = "social.comments.send"
        /// A member suggested for the mention being typed, by short name.
        static func mentionSuggestion(_ name: String) -> String { "social.comments.mention.\(name)" }

        // Photo preuve
        static let photos = "social.photos"
        static let addPhotoButton = "social.photos.add"
        /// A thumbnail, by position (0 = the oldest photo).
        static func photoThumbnail(_ index: Int) -> String { "social.photos.thumb.\(index)" }
        static let photoViewer = "social.photos.viewer"
        static let photoViewerClose = "social.photos.viewer.close"
        static let photoViewerDelete = "social.photos.viewer.delete"
        /// « Ajouter une photo ? » after the user completed the task.
        static let photoPrompt = "social.photos.prompt"
        static let photoPromptAdd = "social.photos.prompt.add"
        static let photoPromptDismiss = "social.photos.prompt.dismiss"

        // Mode absent
        /// « Mode absent » on « Membres » (the current user's row).
        static let awayModeButton = "social.away.open"
        static let awaySheet = "social.away.sheet"
        static let awayFromPicker = "social.away.from"
        static let awayUntilPicker = "social.away.until"
        static let awayAnnounceToggle = "social.away.announce"
        static let awayHandovers = "social.away.handovers"
        static let awaySaveButton = "social.away.save"
        static let awayEndButton = "social.away.end"
        static let awayCancelButton = "social.away.cancel"
        /// The away badge of a member, by display name (« Membres »).
        static func awayBadge(_ name: String) -> String { "social.away.badge.\(name)" }
    }
}
