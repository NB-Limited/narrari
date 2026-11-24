import Foundation
import Observation

// The look the recorder wears, following the settings as they change.
@MainActor
@Observable
public final class PillLookModel {
    public private(set) var look: PillLook
    public private(set) var colour: PillColour

    public init(settings: SettingsStore) {
        look = settings.value(PillSettings.look)
        colour = settings.value(PillSettings.colour)
        let changes = SettingsChanges.updates(of: [PillSettings.look.key, PillSettings.colour.key])
        Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                look = settings.value(PillSettings.look)
                colour = settings.value(PillSettings.colour)
            }
        }
    }
}
