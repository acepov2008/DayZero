# DayZero - the wizard's modules, in load order. Both the GUI and the background engine
# import exactly this list. Core must come first; Engine must come before the Steps.*
# modules, because they register their step types with it when they load.
@(
    'Core.psm1',
    'Config.psm1',
    'System.psm1',
    'State.psm1',
    'Engine.psm1',
    'Session.psm1',
    'Plan.psm1',
    'Download.psm1',
    'Winget.psm1',
    'Office.psm1',
    'Steps.Base.psm1',
    'Steps.Apps.psm1'
)
