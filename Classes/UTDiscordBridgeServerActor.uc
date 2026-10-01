class UTDiscordBridgeServerActor extends Info
    config(UTDiscordBridge);

var config bool bEnabled;
var config string WebhookURL;
var config string RelayURL;
var config string RelayToken;
var config string ServerLabel;
var config bool bForwardChat;
var config bool bForwardTeamChat;
var config bool bForwardGameEvents;
var config bool bForwardPlayerEvents;
var config bool bIgnoreBotEvents;
var config int QueueLimit;
var config int MaxRetries;
var config float RequestTimeout;
var config bool bDebug;

var UTDBBroadcastHandler BridgeBroadcastHandler;
var BroadcastHandler PreviousBroadcastHandler;
var UTDBGameRules BridgeGameRules;
var UTDBPresenceMutator PresenceHook;
var UTDBHttpClient HttpClient;
var bool bReportedMatchStart;

function PostBeginPlay()
{
    Super.PostBeginPlay();

    if (Role != ROLE_Authority || !bEnabled)
        return;

    if (WebhookURL == "")
    {
        Log("UTDB disabled: WebhookURL is empty");
        return;
    }

    if (Left(Caps(RelayURL), 7) != "HTTP://")
    {
        Log("UTDB disabled: RelayURL must use HTTP");
        return;
    }

    HttpClient = Spawn(class'UTDBHttpClient', self);
    if (HttpClient == None)
    {
        Log("UTDB disabled: could not create HTTP client");
        return;
    }

    HttpClient.Initialize(self);
    InstallBroadcastHandler();
    InstallGameRules();
    InstallPresenceHook();

    if (bForwardGameEvents)
        HttpClient.EnqueueMapStart();

    Log("UTDB initialized");
}

event MatchStarting()
{
    Super.MatchStarting();

    if (!bReportedMatchStart && HttpClient != None && bForwardGameEvents)
    {
        bReportedMatchStart = true;
        HttpClient.EnqueueMatchStart();
    }
}

function InstallBroadcastHandler()
{
    if (Level.Game == None || Level.Game.BroadcastHandler == None)
    {
        Log("UTDB chat forwarding disabled: no broadcast handler");
        return;
    }

    PreviousBroadcastHandler = Level.Game.BroadcastHandler;
    BridgeBroadcastHandler = Spawn(class'UTDBBroadcastHandler', self);
    if (BridgeBroadcastHandler == None)
    {
        Log("UTDB chat forwarding disabled: could not create broadcast handler");
        return;
    }

    BridgeBroadcastHandler.Bridge = self;
    BridgeBroadcastHandler.NextBroadcastHandler = PreviousBroadcastHandler;
    BridgeBroadcastHandler.bMuteSpectators = PreviousBroadcastHandler.bMuteSpectators;
    BridgeBroadcastHandler.bPartitionSpectators = PreviousBroadcastHandler.bPartitionSpectators;
    Level.Game.BroadcastHandler = BridgeBroadcastHandler;
}

function InstallGameRules()
{
    if (Level.Game == None)
        return;

    BridgeGameRules = Spawn(class'UTDBGameRules', self);
    if (BridgeGameRules == None)
    {
        Log("UTDB game event forwarding disabled: could not create game rules");
        return;
    }

    BridgeGameRules.Bridge = self;
    Level.Game.AddGameModifier(BridgeGameRules);
}

function InstallPresenceHook()
{
    if (Level.Game == None || Level.Game.BaseMutator == None)
        return;

    PresenceHook = Spawn(class'UTDBPresenceMutator', self);
    if (PresenceHook == None)
    {
        Log("UTDB leave forwarding disabled: could not create presence hook");
        return;
    }

    PresenceHook.Bridge = self;
    Level.Game.BaseMutator.AddMutator(PresenceHook);
}

function ReportChat(PlayerReplicationInfo SenderPRI, string Msg, name Type)
{
    if (HttpClient == None || SenderPRI == None)
        return;

    if (ShouldIgnorePlayer(SenderPRI))
        return;

    if (Type == 'Say' && bForwardChat)
        HttpClient.EnqueueChat(SenderPRI.PlayerName, Msg, false);
    else if (Type == 'TeamSay' && bForwardTeamChat)
        HttpClient.EnqueueChat(SenderPRI.PlayerName, Msg, true);
}

function ReportPlayerJoin(PlayerReplicationInfo PlayerPRI, bool bSpectator)
{
    if (
        HttpClient != None
        && bForwardPlayerEvents
        && PlayerPRI != None
        && !ShouldIgnorePlayer(PlayerPRI)
    )
        HttpClient.EnqueuePlayerEvent(PlayerPRI.PlayerName, true, bSpectator);
}

function ReportPlayerLeave(PlayerReplicationInfo PlayerPRI)
{
    if (
        HttpClient != None
        && bForwardPlayerEvents
        && PlayerPRI != None
        && !ShouldIgnorePlayer(PlayerPRI)
    )
        HttpClient.EnqueuePlayerEvent(
            PlayerPRI.PlayerName,
            false,
            PlayerPRI.bOnlySpectator
        );
}

function bool ShouldIgnorePlayer(PlayerReplicationInfo PlayerPRI)
{
    return bIgnoreBotEvents
        && PlayerPRI != None
        && (
            PlayerPRI.bBot
            || MessagingSpectator(PlayerPRI.Owner) != None
        );
}

function ReportGameEnd(PlayerReplicationInfo Winner, string Reason)
{
    if (HttpClient != None && bForwardGameEvents)
        HttpClient.EnqueueGameEnd(Winner, Reason);
}

function Destroyed()
{
    if (Level.Game != None && Level.Game.BroadcastHandler == BridgeBroadcastHandler)
        Level.Game.BroadcastHandler = PreviousBroadcastHandler;

    if (BridgeBroadcastHandler != None)
    {
        BridgeBroadcastHandler.NextBroadcastHandler = None;
        BridgeBroadcastHandler.Destroy();
    }

    if (HttpClient != None)
        HttpClient.Destroy();

    if (PresenceHook != None)
        PresenceHook.Destroy();

    Super.Destroyed();
}

static function FillPlayInfo(PlayInfo PlayInfo)
{
    local byte Weight;

    Super.FillPlayInfo(PlayInfo);

    PlayInfo.AddSetting("UTDiscordBridge", "bEnabled", "Enable Discord bridge", 255, Weight++, "Check",,, true, true);
    PlayInfo.AddSetting("UTDiscordBridge", "WebhookURL", "Discord webhook URL", 255, Weight++, "Text", "255",, true, true);
    PlayInfo.AddSetting("UTDiscordBridge", "RelayURL", "Local relay URL", 255, Weight++, "Text", "255",, true, true);
    PlayInfo.AddSetting("UTDiscordBridge", "RelayToken", "Relay token", 255, Weight++, "Text", "255",, true, true);
    PlayInfo.AddSetting("UTDiscordBridge", "ServerLabel", "Discord server label", 255, Weight++, "Text", "80",, true, true);
    PlayInfo.AddSetting("UTDiscordBridge", "bForwardChat", "Forward public chat", 255, Weight++, "Check",,, true, true);
    PlayInfo.AddSetting("UTDiscordBridge", "bForwardTeamChat", "Forward team chat", 255, Weight++, "Check",,, true, true);
    PlayInfo.AddSetting("UTDiscordBridge", "bForwardGameEvents", "Forward game events", 255, Weight++, "Check",,, true, true);
    PlayInfo.AddSetting("UTDiscordBridge", "bForwardPlayerEvents", "Forward player joins and leaves", 255, Weight++, "Check",,, true, true);
    PlayInfo.AddSetting("UTDiscordBridge", "bIgnoreBotEvents", "Ignore bots and WebAdmin", 255, Weight++, "Check",,, true, true);
    PlayInfo.AddSetting("UTDiscordBridge", "QueueLimit", "Queue limit", 255, Weight++, "Text", "3;1:500",, true, true);
    PlayInfo.AddSetting("UTDiscordBridge", "MaxRetries", "Maximum retries", 255, Weight++, "Text", "2;0:10",, true, true);
    PlayInfo.AddSetting("UTDiscordBridge", "RequestTimeout", "Relay timeout", 255, Weight++, "Text", "4;1:60",, true, true);
    PlayInfo.AddSetting("UTDiscordBridge", "bDebug", "Debug logging", 255, Weight++, "Check",,, true, true);
}

static event string GetDescriptionText(string PropName)
{
    switch (PropName)
    {
        case "bEnabled": return "Enable chat and game event forwarding.";
        case "WebhookURL": return "Discord HTTPS webhook URL. Stored as plaintext and visible to authorized WebAdmin users.";
        case "RelayURL": return "HTTP endpoint of the local TLS relay.";
        case "RelayToken": return "Optional shared token used to authenticate to the relay.";
        case "ServerLabel": return "Public label shown in Discord. The machine hostname is never used.";
        case "bForwardChat": return "Forward public player chat to Discord.";
        case "bForwardTeamChat": return "Forward private team chat. Leave disabled unless players expect this.";
        case "bForwardGameEvents": return "Forward map changes, match starts, and match ends.";
        case "bForwardPlayerEvents": return "Forward player and spectator join and leave events.";
        case "bIgnoreBotEvents": return "Ignore bot and WebAdmin chat, join, and leave events.";
        case "QueueLimit": return "Maximum number of events held in memory while the relay is unavailable.";
        case "MaxRetries": return "Maximum retry count for temporary relay failures.";
        case "RequestTimeout": return "Connection timeout for the local relay.";
        case "bDebug": return "Log queue and request metadata without logging secrets or chat.";
    }

    return Super.GetDescriptionText(PropName);
}

defaultproperties
{
    bEnabled=True
    RelayURL="http://127.0.0.1:8766/v1/events"
    ServerLabel="UT2004 Server"
    bForwardChat=True
    bForwardTeamChat=False
    bForwardGameEvents=True
    bForwardPlayerEvents=True
    bIgnoreBotEvents=True
    QueueLimit=100
    MaxRetries=5
    RequestTimeout=5.000000
    bDebug=False
}
