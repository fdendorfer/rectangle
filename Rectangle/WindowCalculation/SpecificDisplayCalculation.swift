/// SpecificDisplayCalculation.swift

import Cocoa

class SpecificDisplayCalculation: WindowCalculation {

    override func calculate(_ params: WindowCalculationParameters) -> WindowCalculationResult? {
        let usableScreens = params.usableScreens

        guard usableScreens.numScreens > 1 else { return nil }

        guard let displayIndex = params.action.displayIndex else { return nil }

        let screens = usableScreens.screensOrdered

        guard displayIndex < screens.count else { return nil }

        let targetScreen = screens[displayIndex]

        if targetScreen == usableScreens.currentScreen { return nil }

        let rectParams = params.asRectParams(visibleFrame: targetScreen.adjustedVisibleFrame(params.ignoreTodo))

        if Defaults.attemptMatchOnNextPrevDisplay.userEnabled {
            if let lastAction = params.lastAction,
               let calculation = WindowCalculationFactory.calculationsByAction[lastAction.action] {

                if let windowId = params.window.id {
                    AppDelegate.windowHistory.lastRectangleActions.removeValue(forKey: windowId)
                }

                let newCalculationParams = RectCalculationParameters(
                    window: rectParams.window,
                    visibleFrameOfScreen: rectParams.visibleFrameOfScreen,
                    action: lastAction.action,
                    lastAction: nil)
                let rectResult = calculation.calculateRect(newCalculationParams)

                return WindowCalculationResult(rect: rectResult.rect, screen: targetScreen, resultingAction: lastAction.action)
            }
        }

        // As with next/previous display: a window that fills its display was
        // maximized by someone, whether or not Rectangle has a record of it, and
        // sending it to another display shouldn't un-maximize it.
        if !Defaults.autoMaximize.userDisabled, params.windowFillsCurrentScreen {
            let rectResult = WindowCalculationFactory.maximizeCalculation.calculateRect(rectParams)
            return WindowCalculationResult(rect: rectResult.rect, screen: targetScreen, resultingAction: .maximize)
        }

        let rectResult = calculateRect(rectParams)
        let resultingAction: WindowAction = rectResult.resultingAction ?? params.action
        return WindowCalculationResult(rect: rectResult.rect, screen: targetScreen, resultingAction: resultingAction)
    }

    override func calculateRect(_ params: RectCalculationParameters) -> RectResult {
        return WindowCalculationFactory.centerCalculation.calculateRect(params)
    }
}
