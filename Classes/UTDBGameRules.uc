class UTDBGameRules extends GameRules;

var UTDiscordBridgeServerActor Bridge;
var bool bReportedGameEnd;

function bool CheckEndGame(PlayerReplicationInfo Winner, string Reason)
{
    local bool bAllowed;

    bAllowed = Super.CheckEndGame(Winner, Reason);
    if (bAllowed && !bReportedGameEnd)
    {
        bReportedGameEnd = true;
        if (Bridge != None)
            Bridge.ReportGameEnd(Winner, Reason);
    }

    return bAllowed;
}
