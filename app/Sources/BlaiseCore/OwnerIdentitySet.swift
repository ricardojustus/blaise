import Foundation

public struct OwnerIdentitySet: Sendable, Equatable {
    public static let empty = OwnerIdentitySet(foldedNames: [])

    private let foldedNames: Set<String>

    public init(user: UserIdentity, attendees: [Attendee]) {
        var names = [user.name] + user.aliases
        let email = user.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !email.isEmpty {
            names.append(contentsOf: attendees.compactMap { attendee in
                attendee.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    == email ? attendee.name : nil
            })
        }
        self.init(
            foldedNames: Set(
                names
                    .filter {
                        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    .map(VocabNormalization.canonicalMode)))
    }

    private init(foldedNames: Set<String>) {
        self.foldedNames = foldedNames
    }

    public func contains(_ name: String) -> Bool {
        let folded = VocabNormalization.canonicalMode(name)
        return !folded.isEmpty && foldedNames.contains(folded)
    }
}

public enum DiarizationLabel {
    public static func isMicCluster(_ label: String) -> Bool {
        isIndexed(label, prefix: "M")
    }

    public static func isIndexed(_ label: String, prefix: Character) -> Bool {
        guard label.first == prefix else { return false }
        let digits = label.dropFirst()
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
