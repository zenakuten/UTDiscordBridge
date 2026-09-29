class UTDBPresenceMutator extends Mutator
    CacheExempt;

var UTDiscordBridgeServerActor Bridge;

function NotifyLogout(Controller Exiting)
{
    if (
        Bridge != None
        && PlayerController(Exiting) != None
        && Exiting.PlayerReplicationInfo != None
    )
        Bridge.ReportPlayerLeave(Exiting.PlayerReplicationInfo);

    Super.NotifyLogout(Exiting);
}

defaultproperties
{
    bUserAdded=False
    bAddToServerPackages=False
}
