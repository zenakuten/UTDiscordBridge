class UTDBBroadcastHandler extends BroadcastHandler;

var UTDiscordBridgeServerActor Bridge;
var bool bLastBroadcastAllowed;

event AllowBroadcastLocalized(Actor Sender, class<LocalMessage> Message, optional int Switch, optional PlayerReplicationInfo RelatedPRI_1, optional PlayerReplicationInfo RelatedPRI_2, optional Object OptionalObject)
{
    if (
        Bridge != None
        && Level.Game != None
        && Message == Level.Game.GameMessageClass
        && (Switch == 1 || Switch == 16)
    )
        Bridge.ReportPlayerJoin(RelatedPRI_1, Switch == 16);

    if (NextBroadcastHandler != None)
        NextBroadcastHandler.AllowBroadcastLocalized(Sender, Message, Switch, RelatedPRI_1, RelatedPRI_2, OptionalObject);
    else
        Super.AllowBroadcastLocalized(Sender, Message, Switch, RelatedPRI_1, RelatedPRI_2, OptionalObject);
}

function bool AllowsBroadcast(Actor Broadcaster, int MsgLength)
{
    if (NextBroadcastHandler != None)
        bLastBroadcastAllowed = NextBroadcastHandler.AllowsBroadcast(Broadcaster, MsgLength);
    else
        bLastBroadcastAllowed = Super.AllowsBroadcast(Broadcaster, MsgLength);

    return bLastBroadcastAllowed;
}

function Broadcast(Actor Sender, coerce string Msg, optional name Type)
{
    local PlayerReplicationInfo SenderPRI;

    bLastBroadcastAllowed = false;
    Super.Broadcast(Sender, Msg, Type);

    if (!bLastBroadcastAllowed || Bridge == None)
        return;

    if (Pawn(Sender) != None)
        SenderPRI = Pawn(Sender).PlayerReplicationInfo;
    else if (Controller(Sender) != None)
        SenderPRI = Controller(Sender).PlayerReplicationInfo;

    Bridge.ReportChat(SenderPRI, Msg, Type);
}

function BroadcastTeam(Controller Sender, coerce string Msg, optional name Type)
{
    bLastBroadcastAllowed = false;
    Super.BroadcastTeam(Sender, Msg, Type);

    if (bLastBroadcastAllowed && Bridge != None && Sender != None)
        Bridge.ReportChat(Sender.PlayerReplicationInfo, Msg, Type);
}

function BroadcastText(PlayerReplicationInfo SenderPRI, PlayerController Receiver, coerce string Msg, optional name Type)
{
    if (NextBroadcastHandler != None)
        NextBroadcastHandler.BroadcastText(SenderPRI, Receiver, Msg, Type);
    else
        Receiver.TeamMessage(SenderPRI, Msg, Type);
}

function BroadcastLocalized(Actor Sender, PlayerController Receiver, class<LocalMessage> Message, optional int Switch, optional PlayerReplicationInfo RelatedPRI_1, optional PlayerReplicationInfo RelatedPRI_2, optional Object OptionalObject)
{
    if (NextBroadcastHandler != None)
        NextBroadcastHandler.BroadcastLocalized(Sender, Receiver, Message, Switch, RelatedPRI_1, RelatedPRI_2, OptionalObject);
    else
        Receiver.ReceiveLocalizedMessage(Message, Switch, RelatedPRI_1, RelatedPRI_2, OptionalObject);
}
