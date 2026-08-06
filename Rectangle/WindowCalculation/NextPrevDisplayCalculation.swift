/// NextPrevDisplayCalculation.swift

import Cocoa

class NextPrevDisplayCalculation: WindowCalculation {
    
    override func calculate(_ params: WindowCalculationParameters) -> WindowCalculationResult? {
        let usableScreens = params.usableScreens
        
        guard usableScreens.numScreens > 1 else { return nil }

        var screen: NSScreen?
        
        if params.action == .nextDisplay {
            screen = usableScreens.adjacentScreens?.next
        } else if params.action == .previousDisplay {
            screen = usableScreens.adjacentScreens?.prev
        }

        if let screen = screen {
            let rectParams = params.asRectParams(visibleFrame: screen.adjustedVisibleFrame(params.ignoreTodo))
            
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
                    
                    return WindowCalculationResult(rect: rectResult.rect, screen: screen, resultingAction: lastAction.action)
                }
            }
            
            // calculateRect re-maximizes based on Rectangle's own action
            // history, which covers nothing that Rectangle didn't maximize
            // itself, and nothing whose history was cleared by the window being
            // moved. A window that currently fills its display was maximized by
            // someone, and moving it shouldn't be what un-maximizes it.
            if !Defaults.autoMaximize.userDisabled, params.windowFillsCurrentScreen {
                let rectResult = WindowCalculationFactory.maximizeCalculation.calculateRect(rectParams)
                return WindowCalculationResult(rect: rectResult.rect, screen: screen, resultingAction: .maximize)
            }

            let rectResult = calculateRect(rectParams)
            let resultingAction: WindowAction = rectResult.resultingAction ?? params.action
            return WindowCalculationResult(rect: rectResult.rect, screen: screen, resultingAction: resultingAction)
        }
        
        return nil
    }
    
    override func calculateRect(_ params: RectCalculationParameters) -> RectResult {
        if params.lastAction?.action == .maximize && !Defaults.autoMaximize.userDisabled {
            let rectResult = WindowCalculationFactory.maximizeCalculation.calculateRect(params)
            return RectResult(rectResult.rect, resultingAction: .maximize)
        }
        
        return WindowCalculationFactory.centerCalculation.calculateRect(params)
    }
}
