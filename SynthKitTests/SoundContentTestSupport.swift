import Foundation
@testable import SynthKit

/// Test-only sugar for the sounds that are synth patches.
///
/// Increment 005 gave a sound two possible kinds — a synth patch or an
/// instrument variant — so `SoundEntry` and `EmbeddedSound` now hold a
/// `SoundContent` and answer `synthPatch` as an optional. That is deliberate in
/// the product code: a consumer that only knows how to render a patch has to
/// say what it does about a cello rather than silently rendering the default
/// voice over one.
///
/// It is not useful in the suites written before that, every one of which is
/// about a synth sound and builds a synth fixture two lines above. These trap
/// rather than substituting: reaching a nil here would mean the *fixture* is
/// wrong, which is a broken test rather than a failing assertion, and a
/// substitute would turn that into a quietly passing one.
///
/// Deliberately test-only. There is no such accessor in `SynthKit`, and adding
/// one would put back exactly the silent fallback the model removed.
extension SoundEntry {
    var patch: SynthPatch {
        guard let patch = synthPatch else {
            preconditionFailure(
                "“\(name)” is an instrument variant, not a synth patch. A test reaching for "
                    + "`patch` on one is asking the wrong question of its fixture."
            )
        }
        return patch
    }
}

extension EmbeddedSound {
    var patch: SynthPatch {
        guard let patch = content.synthPatch else {
            preconditionFailure(
                "The embedded copy of “\(name)” is an instrument variant, not a synth patch."
            )
        }
        return patch
    }
}
