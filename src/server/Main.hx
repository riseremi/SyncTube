package server;

import js.lib.Date;
import sys.FileSystem;
import sys.io.File;
import haxe.Timer;
import Client.ClientData;
import haxe.Json;
import js.Node.process;
import js.Node.__dirname;
import js.npm.ws.Server as WSServer;
import js.npm.ws.WebSocket;
import js.node.Http;
import Types;
using ClientTools;
using Lambda;

class Main {

	final rootDir = '$__dirname/..';
	final wss:WSServer;
	final config:Config;
	final clients:Array<Client> = [];
	final freeIds:Array<Int> = [];
	final videoList:Array<VideoItem> = [];
	final videoTimer = new VideoTimer();
	final messages:Array<Message> = [];

	static function main():Void new Main();

	public function new(port = 4200, wsPort = 4201) {
		config = getUserConfig();
		wss = new WSServer({port: wsPort});
		wss.on("connection", onConnect);
		function exit() {
			process.exit();
		}
		process.on("exit", exit);
		process.on("SIGINT", exit); // ctrl+c
		process.on("uncaughtException", (log) -> {
			trace(log);
		});
		process.on("unhandledRejection", (reason, promise) -> {
			trace("Unhandled Rejection at:", reason);
		});

		Utils.getGlobalIp(ip -> {
			final local = Utils.getLocalIp();
			trace('Local: http://$local:$port');
			trace('Global: http://$ip:$port');
		});

		final dir = '$rootDir/res';
		HttpServer.init(dir);
		Lang.init('$dir/langs');

		Http.createServer((req, res) -> {
			HttpServer.serveFiles(req, res);
		}).listen(port);
	}

	function getUserConfig():Config {
		final config:Config = Json.parse(File.getContent('$rootDir/default-config.json'));
		final customPath = '$rootDir/config.json';
		if (!FileSystem.exists(customPath)) return config;
		final customConfig:Config = Json.parse(File.getContent(customPath));
		for (field in Reflect.fields(customConfig)) {
			if (Reflect.field(config, field) == null) trace('Warning: config field "$field" is unknown');
			Reflect.setField(config, field, Reflect.field(customConfig, field));
		}
		return config;
	}

	function onConnect(ws:WebSocket, req):Void {
		final ip = req.connection.remoteAddress;
		final id = freeIds.length > 0 ? freeIds.shift() : clients.length;
		final name = 'Guest ${id + 1}';
		trace('$name connected ($ip)');
		final isAdmin = req.connection.localAddress == ip;
		final client = new Client(ws, id, name, 0);
		if (isAdmin) client.group.set(Admin);
		clients.push(client);
		if (clients.length == 1 && videoList.length > 0)
			if (videoTimer.isPaused()) videoTimer.play();

		send(client, {
			type: Connected,
			connected: {
				config: config,
				history: messages,
				isUnknownClient: true,
				clientName: client.name,
				clients: [
					for (client in clients) client.getData()
				],
				videoList: videoList
			}
		});
		sendClientList();

		ws.on("message", data -> {
			onMessage(client, Json.parse(data));
		});
		ws.on("close", err -> {
			trace('Client ${client.name} disconnected');
			sortedPush(freeIds, client.id);
			clients.remove(client);
			sendClientList();
			if (client.isLeader) {
				if (videoTimer.isPaused()) videoTimer.play();
			}
			if (clients.length == 0) {
				if (waitVideoStart != null) waitVideoStart.stop();
				videoTimer.pause();
			}
		});
	}

	function sortedPush(ids:Array<Int>, id:Int):Void {
		for (i in 0...ids.length) {
			final n = ids[i];
			if (id < n) {
				ids.insert(i, id);
				return;
			}
		}
		ids.push(id);
	}

	function onMessage(client:Client, data:WsEvent):Void {
		switch (data.type) {
			case Connected:
			case UpdateClients:
				sendClientList();
			case Login:
				final name = data.login.clientName;
				if (name.length == 0 || name.length > config.maxLoginLength
					|| clients.getByName(name) != null) {
					send(client, {type: LoginError});
					return;
				}
				client.name = data.login.clientName;
				send(client, {
					type: data.type,
					login: {
						isUnknownClient: true,
						clientName: client.name,
						clients: clientList()
					}
				});
				sendClientList();
			case LoginError:
			case Logout:
				final oldName = client.name;
				final id = clients.indexOf(client) + 1;
				client.name = 'Guest $id';
				send(client, {
					type: data.type,
					logout: {
						oldClientName: oldName,
						clientName: client.name,
						clients: clientList()
					}
				});
				sendClientList();
			case Message:
				var text = data.message.text;
				if (text.length == 0) return;
				if (text.length > config.maxMessageLength) {
					text = text.substr(0, config.maxMessageLength);
				}
				data.message.text = text;
				data.message.clientName = client.name;
				final time = "[" + new Date().toTimeString().split(" ")[0] + "] ";
				messages.push({text: text, name: client.name, time: time});
				if (messages.length > config.serverChatHistory) messages.shift();
				broadcast(data);
			case AddVideo:
				if (data.addVideo.atEnd) videoList.push(data.addVideo.item);
				else videoList.insert(1, data.addVideo.item);
				broadcast(data);
				// Initial timer start if VideoLoaded is not happen
				if (videoList.length == 1) restartWaitTimer();
			case VideoLoaded:
				// Called if client loads next video and can play it
				prepareVideoPlayback();
			case RemoveVideo:
				if (videoList.length == 0) return;
				final url = data.removeVideo.url;
				if (videoList[0].url == url) videoTimer.stop();
				videoList.remove(
					videoList.find(item -> item.url == url)
				);
				broadcast(data);
				if (videoList.length > 0) restartWaitTimer();
			case Pause:
				if (videoList.length == 0) return;
				if (!client.isLeader) return;
				videoTimer.pause();
				broadcast(data);
			case Play:
				if (videoList.length == 0) return;
				if (!client.isLeader) return;
				videoTimer.play();
				broadcast(data);
			case GetTime:
				if (videoList.length == 0) return;
				if (videoTimer.getTime() > videoList[0].duration) {
					videoTimer.stop();
					onMessage(client, {
						type: RemoveVideo,
						removeVideo: {
							url: videoList[0].url
						}
					});
					return;
				}
				send(client, {
					type: GetTime, getTime: {
					time: videoTimer.getTime(),
					paused: videoTimer.isPaused()
				}});
			case SetTime:
				if (videoList.length == 0) return;
				if (!client.isLeader) return;
				videoTimer.setTime(data.setTime.time);
				broadcastExcept(client, data);
			case Rewind:
				if (videoList.length == 0) return;
				// TODO permission
				data.rewind.time += videoTimer.getTime();
				if (data.rewind.time < 0) data.rewind.time = 0;
				videoTimer.setTime(data.rewind.time);
				broadcast(data);
			case SetLeader:
				clients.setLeader(data.setLeader.clientName);
				broadcast({
					type: SetLeader, setLeader: {
						clientName: data.setLeader.clientName
					}
				});
				if (videoList.length == 0) return;
				if (!clients.hasLeader()) {
					if (videoTimer.isPaused()) videoTimer.play();
					broadcast({
						type: Play, play: {
							time: videoTimer.getTime()
						}
					});
				}
			case ClearChat:
				if (client.isAdmin) broadcast(data);
			case ClearPlaylist:
				videoTimer.stop();
				videoList.resize(0);
				broadcast(data);
			case ShufflePlaylist:
				if (videoList.length == 0) return;
				final first = videoList.shift();
				Utils.shuffle(videoList);
				videoList.unshift(first);
				broadcast({type: UpdatePlaylist, updatePlaylist: {
					videoList: videoList
				}});
			case UpdatePlaylist:
		}
	}

	function clientList():Array<ClientData> {
		return [
			for (client in clients) client.getData()
		];
	}

	function sendClientList():Void {
		broadcast({
			type: UpdateClients,
			updateClients: {
				clients: clientList()
			}
		});
	}

	function send(client:Client, data:WsEvent):Void {
		client.ws.send(Json.stringify(data), null);
	}

	function broadcast(data:WsEvent):Void {
		final json = Json.stringify(data);
		for (client in clients) client.ws.send(json, null);
	}

	function broadcastExcept(skipped:Client, data:WsEvent):Void {
		final json = Json.stringify(data);
		for (client in clients) {
			if (client == skipped) continue;
			client.ws.send(json, null);
		}
	}

	var waitVideoStart:Timer;
	var loadedClientsCount = 0;

	function restartWaitTimer():Void {
		if (waitVideoStart != null) waitVideoStart.stop();
		waitVideoStart = Timer.delay(startVideoPlayback, 3000);
	}

	function prepareVideoPlayback():Void {
		if (videoTimer.isStarted) return;
		loadedClientsCount++;
		if (loadedClientsCount == 1) restartWaitTimer();
		if (loadedClientsCount >= clients.length) startVideoPlayback();
	}

	function startVideoPlayback():Void {
		if (waitVideoStart != null) waitVideoStart.stop();
		loadedClientsCount = 0;
		broadcast({type: VideoLoaded});
		videoTimer.start();
	}

}
