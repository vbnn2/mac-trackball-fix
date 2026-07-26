//
// --------------------------------------------------------------------------
// ScrollModifiersSwift.swift
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2021
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

import Cocoa


extension MFScrollModificationResult: Hashable {
    
    /// Make hashable so we can use this as dict key for cache
    
    public static func == (lhs: MFScrollModificationResult, rhs: MFScrollModificationResult) -> Bool {
        return lhs.inputMod == rhs.inputMod && lhs.effectMod == rhs.effectMod
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(inputMod.rawValue)
        hasher.combine(effectMod.rawValue)
    }
    
}

@objc class ScrollModifiers: NSObject {

    private struct Resolution {
        let result: MFScrollModificationResult
        let modifiedScrollDictionary: NSDictionary?
    }

    private static func resolve(activeModifiers: NSDictionary) -> Resolution {
        let emptyResult = MFScrollModificationResult.init(inputMod: kMFScrollInputModificationNone,
                                                          effectMod: kMFScrollEffectModificationNone)
        var result = emptyResult

        let activeModifications = Remap.modifications(withModifiers: activeModifiers) ?? NSDictionary()
        guard let modifiedScrollDict = activeModifications[kMFTriggerScroll] else {
            return Resolution(result: result, modifiedScrollDictionary: nil)
        }
        guard let modifiedScrollDict = modifiedScrollDict as? NSDictionary else {
            assertionFailure("Invalid scroll modification dictionary")
            return Resolution(result: result, modifiedScrollDictionary: nil)
        }

        if let inputModification = modifiedScrollDict[kMFModifiedScrollDictKeyInputModificationType] as? String {
            switch inputModification {
            case kMFModifiedScrollInputModificationTypePrecisionScroll:
                result.inputMod = kMFScrollInputModificationPrecise
            case kMFModifiedScrollInputModificationTypeQuickScroll:
                result.inputMod = kMFScrollInputModificationQuick
            default:
                assertionFailure("Unknown modified scroll input type")
            }
        }

        if let effectModification = modifiedScrollDict[kMFModifiedScrollDictKeyEffectModificationType] as? String {
            switch effectModification {
            case kMFModifiedScrollEffectModificationTypeZoom:
                result.effectMod = kMFScrollEffectModificationZoom
            case kMFModifiedScrollEffectModificationTypeHorizontalScroll:
                result.effectMod = kMFScrollEffectModificationHorizontalScroll
            case kMFModifiedScrollEffectModificationTypeRotate:
                result.effectMod = kMFScrollEffectModificationRotate
            case kMFModifiedScrollEffectModificationTypeFourFingerPinch:
                result.effectMod = kMFScrollEffectModificationFourFingerPinch
            case kMFModifiedScrollEffectModificationTypeCommandTab:
                result.effectMod = kMFScrollEffectModificationCommandTab
            case kMFModifiedScrollEffectModificationTypeThreeFingerSwipeHorizontal:
                result.effectMod = kMFScrollEffectModificationThreeFingerSwipeHorizontal
            case kMFModifiedScrollEffectModificationTypeAddModeFeedback:
                result.effectMod = kMFScrollEffectModificationAddModeFeedback
            default:
                assertionFailure("Unknown modified scroll effect type")
            }
        }

        return Resolution(result: result, modifiedScrollDictionary: modifiedScrollDict)
    }

    /// Pure resolution for the event path. Usage feedback is intentionally separate so
    /// sampling every physical report cannot zombify buttons or emit Add Mode feedback
    /// repeatedly.
    @objc public static func currentModifications(event: CGEvent) -> MFScrollModificationResult {
        let activeModifiers = Modifiers.modifiers(with: event)
        return resolve(activeModifiers: activeModifiers).result
    }

    /// Pure resolution for modifier-change callbacks, where no wheel event exists.
    @objc(currentModificationsWithActiveModifiers:)
    public static func currentModifications(activeModifiers: NSDictionary) -> MFScrollModificationResult {
        return resolve(activeModifiers: activeModifiers).result
    }

    /// Run the one-shot side effects for an effective scroll-modifier activation.
    @objc public static func handleCurrentModificationHasBeenUsed(event: CGEvent) {
        let activeModifiers = Modifiers.modifiers(with: event)
        let resolution = resolve(activeModifiers: activeModifiers)
        let resultIsEmpty = resolution.result.inputMod == kMFScrollInputModificationNone
            && resolution.result.effectMod == kMFScrollEffectModificationNone
        guard !resultIsEmpty else { return }

        Modifiers.handleModificationHasBeenUsed(withModifiers: activeModifiers)

        if resolution.result.effectMod == kMFScrollEffectModificationAddModeFeedback,
           let modifiedScrollDict = resolution.modifiedScrollDictionary {
            let payload = modifiedScrollDict.mutableCopy() as! NSMutableDictionary
            payload.removeObject(forKey: kMFModifiedScrollDictKeyEffectModificationType)
            Remap.sendAddModeFeedback(payload)
        }
    }

    /// Utility
    @objc static func scrollModsAreEqual(_ mods1: MFScrollModificationResult, other mods2: MFScrollModificationResult) -> Bool {
        return mods1.effectMod == mods2.effectMod && mods1.inputMod == mods2.inputMod
    }
    
}
