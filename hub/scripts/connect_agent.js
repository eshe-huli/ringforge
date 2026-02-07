#!/usr/bin/env node
/**
 * RingForge Agent Connect Script
 * 
 * Connects to a RingForge hub as an agent via Phoenix Channels WebSocket.
 * 
 * Usage:
 *   node connect_agent.js --url wss://your-server.com --key rf_live_XXX --name "My Agent"
 *   
 * Or with env vars:
 *   RINGFORGE_URL=wss://your-server.com RINGFORGE_KEY=rf_live_XXX node connect_agent.js
 * 
 * Requires: npm install ws (or use Bun/Deno which have built-in WebSocket)
 */

const WebSocket = require("ws");

// ── Config ──────────────────────────────────────────────────
const config = {
  url: process.env.RINGFORGE_URL || process.argv.find((a, i) => process.argv[i - 1] === "--url") || "ws://localhost:4000",
  apiKey: process.env.RINGFORGE_KEY || process.argv.find((a, i) => process.argv[i - 1] === "--key") || "",
  name: process.env.RINGFORGE_NAME || process.argv.find((a, i) => process.argv[i - 1] === "--name") || "agent-" + Math.random().toString(36).slice(2, 8),
  framework: process.env.RINGFORGE_FRAMEWORK || process.argv.find((a, i) => process.argv[i - 1] === "--framework") || "openclaw",
  capabilities: (process.env.RINGFORGE_CAPS || process.argv.find((a, i) => process.argv[i - 1] === "--caps") || "chat,code,search").split(","),
  state: "online",
};

if (!config.apiKey) {
  console.error("❌ No API key provided.");
  console.error("   Use: --key rf_live_XXX or set RINGFORGE_KEY=rf_live_XXX");
  console.error("   Get a key from the dashboard Settings page.");
  process.exit(1);
}

if (!config.apiKey.startsWith("rf_live_")) {
  if (config.apiKey.startsWith("rf_admin_")) {
    console.error("❌ You're using an admin key (rf_admin_*). Agents need a live key (rf_live_*).");
    console.error("   Admin keys are for the dashboard only.");
  } else {
    console.error("❌ Invalid API key format. Keys start with 'rf_live_' for agents.");
  }
  process.exit(1);
}

// ── Phoenix Channel Protocol ────────────────────────────────
let refCounter = 0;
let ws;
let heartbeatInterval;
let joinRef;
let currentFleetTopic = null;

function makeRef() {
  return String(++refCounter);
}

function send(msg) {
  const raw = JSON.stringify(msg);
  ws.send(raw);
}

function pushChannel(topic, event, payload = {}) {
  const ref = makeRef();
  send([joinRef, ref, topic, event, payload]);
  return ref;
}

function connect() {
  const wsUrl = `${config.url}/ws/websocket?vsn=2.0.0&api_key=${encodeURIComponent(config.apiKey)}&agent=${encodeURIComponent(JSON.stringify({
    name: config.name,
    framework: config.framework,
    capabilities: config.capabilities,
  }))}`;

  console.log(`🔌 Connecting as "${config.name}" to ${config.url}...`);

  ws = new WebSocket(wsUrl);

  ws.on("open", () => {
    console.log("✅ WebSocket connected");

    // Phoenix heartbeat
    heartbeatInterval = setInterval(() => {
      send([null, makeRef(), "phoenix", "heartbeat", {}]);
    }, 30000);

    // Join fleet channel (fleet ID comes from the API key's fleet)
    joinRef = makeRef();
    // The server assigns fleet from the api_key, so we join "fleet:*"
    // Actually we need the fleet_id. Let's join with a wildcard approach:
    // The socket assigns fleet_id, but we need to know it. 
    // Phoenix channels require the exact topic. Let's use the phx_join approach.
    // We'll discover fleet_id from the roster response.
    
    // For now, we need the fleet_id. It's assigned by the socket on connect.
    // The channel topic must match socket.assigns.fleet_id.
    // Since we don't know it client-side, we'll try to join "fleet:default"
    // or we need an endpoint to discover it.
    
    // Actually, looking at the socket code: it assigns fleet_id from the API key.
    // We just need to know our fleet_id. Let's query the health endpoint first.
    // Or better: the server will reject mismatched fleet_ids.
    // The API key resolves to a specific fleet. We need that fleet_id.
    
    // Workaround: try joining and the server will tell us if we got it wrong.
    // Or: use an HTTP endpoint to resolve the key first.
    resolveFleetAndJoin();
  });

  ws.on("message", (data) => {
    const msg = JSON.parse(data.toString());
    // Phoenix Channel format: [joinRef, ref, topic, event, payload]
    const [jRef, ref, topic, event, payload] = msg;

    if (event === "phx_reply") {
      if (payload.status === "ok") {
        if (topic.startsWith("fleet:")) {
          console.log("🎯 Joined fleet channel:", topic);
          currentFleetTopic = topic;
          onJoined(topic, payload.response);
        }
      } else if (payload.status === "error") {
        const err = payload.response || {};
        console.error(`❌ ${err.message || "Error joining " + topic}`);
        if (err.fix) console.error(`   Fix: ${err.fix}`);
        if (err.your_fleet_id) console.error(`   Your fleet ID: ${err.your_fleet_id}`);
        if (err.reason === "fleet_id_mismatch") {
          // Auto-retry with correct fleet
          console.log(`   Auto-retrying with correct fleet...`);
          joinFleet(err.your_fleet_id);
          return;
        }
      }
    } else if (event === "presence:roster") {
      const agents = payload?.payload?.agents || [];
      console.log(`👥 Roster: ${agents.length} agent(s)`);
      agents.forEach((a) => {
        console.log(`   ${a.state === "online" ? "🟢" : "⚪"} ${a.name} (${a.agent_id}) — ${a.state}`);
      });
    } else if (event === "presence:joined") {
      const p = payload?.payload || payload;
      console.log(`→ Agent joined: ${p.name || p.agent_id}`);
    } else if (event === "presence:left") {
      const p = payload?.payload || payload;
      console.log(`← Agent left: ${p.agent_id}`);
    } else if (event === "presence:state_changed") {
      const p = payload?.payload || payload;
      console.log(`~ State changed: ${p.name} → ${p.state}${p.task ? ` (${p.task})` : ""}`);
    } else if (event === "activity:broadcast") {
      const p = payload?.payload || payload;
      console.log(`⚡ Activity: [${p.kind}] ${p.from?.name || "unknown"} — ${p.description}`);
    } else if (event === "direct:message") {
      const p = payload?.payload || payload;
      const fromName = p.from?.name || p.from?.agent_id || "unknown";
      const fromId = p.from?.agent_id;
      const msg = p.message || {};
      
      // Handle structured messages by type
      handleIncomingDM(fromName, fromId, msg);
    } else if (event === "system:quota_warning") {
      console.log("⚠️  Quota warning:", JSON.stringify(payload));
    } else if (topic === "phoenix" && event === "phx_reply") {
      // heartbeat ack, ignore
    } else {
      console.log(`📨 ${topic} :: ${event}`, JSON.stringify(payload).slice(0, 200));
    }
  });

  ws.on("close", (code, reason) => {
    const reasonStr = reason ? reason.toString() : "";
    clearInterval(heartbeatInterval);
    
    switch (code) {
      case 1000:
        console.log("🔌 Disconnected normally.");
        return;
      case 1008:
        console.error("❌ Disconnected: policy violation. Your API key may be invalid or revoked.");
        console.error("   Fix: Check your key with: curl https://your-server.com/api/connect/check?api_key=YOUR_KEY");
        break;
      case 1011:
        console.error("❌ Disconnected: server error. The hub may be restarting or misconfigured.");
        console.error("   Fix: Check hub health: curl https://your-server.com/api/health");
        break;
      case 1006:
        console.error("❌ Disconnected: connection lost (no close frame).");
        console.error("   This usually means the server crashed or network dropped.");
        break;
      default:
        console.log(`🔌 Disconnected (${code}): ${reasonStr}`);
    }
    
    console.log("   Reconnecting in 3s...");
    setTimeout(connect, 3000);
  });

  ws.on("error", (err) => {
    if (err.message.includes("500")) {
      console.error("❌ Server returned 500. Possible causes:");
      console.error("   • Missing vsn=2.0.0 in WebSocket URL (protocol mismatch)");
      console.error("   • Hub is starting up — wait a few seconds");
      console.error("   • Check: curl https://your-server.com/api/health");
    } else if (err.message.includes("401") || err.message.includes("403")) {
      console.error("❌ Authentication failed (${err.message}).");
      console.error("   Fix: Verify your API key: curl https://your-server.com/api/connect/check?api_key=YOUR_KEY");
    } else if (err.message.includes("ECONNREFUSED") || err.message.includes("ENOTFOUND")) {
      console.error("❌ Cannot reach server:", err.message);
      console.error("   Fix: Check the URL is correct and the hub is running.");
    } else {
      console.error("❌ WebSocket error:", err.message);
    }
  });
}

function resolveFleetAndJoin() {
  const fleetId = process.env.RINGFORGE_FLEET_ID
    || process.argv.find((a, i) => process.argv[i - 1] === "--fleet")
    || "";

  if (fleetId) {
    joinFleet(fleetId);
  } else {
    console.error("❌ Fleet ID required. Pass --fleet <id> or set RINGFORGE_FLEET_ID");
    console.log("   Find it in the dashboard Settings page.");
    process.exit(1);
  }
}

function joinFleet(fleetId) {
  console.log(`📡 Joining fleet: ${fleetId}`);
  const topic = `fleet:${fleetId}`;
  joinRef = makeRef();
  send([joinRef, makeRef(), topic, "phx_join", {
    payload: {
      name: config.name,
      framework: config.framework,
      capabilities: config.capabilities,
      state: config.state,
    }
  }]);
}

function onJoined(topic, response) {
  console.log("🚀 Connected to mesh! Commands:");
  console.log("  ── Presence ──");
  console.log("  busy <task>                — set busy with task");
  console.log("  online / away              — change state");
  console.log("  roster                     — list agents");
  console.log("  ── Messaging ──");
  console.log("  dm <agent> <text>          — text DM");
  console.log("  ask <agent> <question>     — structured query");
  console.log("  assign <agent> <task> [desc] — delegate task");
  console.log("  status <agent>             — request agent status");
  console.log("  data <agent> <label> <json> — send data payload");
  console.log("  send <agent> <json>        — raw structured message");
  console.log("  ── Fleet ──");
  console.log("  activity <desc>            — broadcast activity");
  console.log("  task <desc> / done <desc>  — task lifecycle");
  console.log("  memory set|get|list <key>  — shared memory");
  console.log("  quit                       — disconnect");
  console.log("");

  // Read stdin for interactive commands
  const readline = require("readline");
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout, prompt: "ringforge> " });
  rl.prompt();

  rl.on("line", (line) => {
    const trimmed = line.trim();
    if (!trimmed) { rl.prompt(); return; }

    const [cmd, ...args] = trimmed.split(" ");

    switch (cmd) {
      case "busy":
        pushChannel(topic, "presence:update", {
          payload: { state: "busy", task: args.join(" ") || "working" }
        });
        console.log("→ State: busy");
        break;

      case "online":
        pushChannel(topic, "presence:update", {
          payload: { state: "online", task: null }
        });
        console.log("→ State: online");
        break;

      case "away":
        pushChannel(topic, "presence:update", {
          payload: { state: "away" }
        });
        console.log("→ State: away");
        break;

      case "activity":
        pushChannel(topic, "activity:broadcast", {
          payload: {
            kind: "custom",
            description: args.join(" ") || "ping",
            tags: ["manual"],
          }
        });
        console.log("→ Activity broadcast");
        break;

      case "task":
        pushChannel(topic, "activity:broadcast", {
          payload: {
            kind: "task_started",
            description: args.join(" ") || "new task",
            tags: ["task"],
          }
        });
        console.log("→ Task started");
        break;

      case "done":
        pushChannel(topic, "activity:broadcast", {
          payload: {
            kind: "task_completed",
            description: args.join(" ") || "task finished",
            tags: ["task"],
          }
        });
        console.log("→ Task completed");
        break;

      case "dm":
        const toAgent = args[0];
        const dmText = args.slice(1).join(" ");
        if (!toAgent || !dmText) {
          console.log("Usage: dm <agent_id> <message>");
        } else {
          reply(toAgent, { type: "text", text: dmText });
          console.log(`→ DM sent to ${toAgent}`);
        }
        break;

      case "ask": {
        // ask <agent_id> <question>
        const askTo = args[0];
        const question = args.slice(1).join(" ");
        if (!askTo || !question) {
          console.log("Usage: ask <agent_id> <question>");
        } else {
          reply(askTo, { type: "query", ref: makeRef(), question });
          console.log(`→ Query sent to ${askTo}`);
        }
        break;
      }

      case "assign": {
        // assign <agent_id> <task_name> [description...]
        const assignTo = args[0];
        const taskName = args[1];
        const taskDesc = args.slice(2).join(" ") || taskName;
        if (!assignTo || !taskName) {
          console.log("Usage: assign <agent_id> <task_name> [description]");
        } else {
          reply(assignTo, {
            type: "task_request",
            ref: makeRef(),
            task: taskName,
            description: taskDesc,
            priority: "normal",
            payload: { assigned_by: config.name, assigned_at: new Date().toISOString() },
          });
          console.log(`→ Task '${taskName}' assigned to ${assignTo}`);
        }
        break;
      }

      case "send": {
        // send <agent_id> <json_payload>
        const sendTo = args[0];
        const jsonStr = args.slice(1).join(" ");
        if (!sendTo || !jsonStr) {
          console.log("Usage: send <agent_id> <json>");
        } else {
          try {
            const parsed = JSON.parse(jsonStr);
            reply(sendTo, parsed);
            console.log(`→ Structured message sent to ${sendTo}`);
          } catch (e) {
            console.log(`❌ Invalid JSON: ${e.message}`);
          }
        }
        break;
      }

      case "status": {
        // status <agent_id>  — request agent status
        const statusTo = args[0];
        if (!statusTo) {
          console.log("Usage: status <agent_id>");
        } else {
          reply(statusTo, { type: "status_request" });
          console.log(`→ Status request sent to ${statusTo}`);
        }
        break;
      }

      case "data": {
        // data <agent_id> <label> <json_payload>
        const dataTo = args[0];
        const label = args[1];
        const dataJson = args.slice(2).join(" ");
        if (!dataTo || !label || !dataJson) {
          console.log("Usage: data <agent_id> <label> <json>");
        } else {
          try {
            reply(dataTo, { type: "data", label, format: "json", payload: JSON.parse(dataJson) });
            console.log(`→ Data '${label}' sent to ${dataTo}`);
          } catch (e) {
            console.log(`❌ Invalid JSON: ${e.message}`);
          }
        }
        break;
      }

      case "roster":
        pushChannel(topic, "presence:roster", {});
        break;

      case "memory":
        if (args[0] === "set" && args[1]) {
          pushChannel(topic, "memory:set", {
            payload: { key: args[1], value: args.slice(2).join(" ") || "test" }
          });
          console.log(`→ Memory set: ${args[1]}`);
        } else if (args[0] === "get" && args[1]) {
          pushChannel(topic, "memory:get", { payload: { key: args[1] } });
        } else if (args[0] === "list") {
          pushChannel(topic, "memory:list", { payload: {} });
        } else {
          console.log("Usage: memory set|get|list <key> [value]");
        }
        break;

      case "quit":
      case "exit":
        console.log("👋 Disconnecting...");
        ws.close();
        process.exit(0);

      default:
        console.log(`Unknown command: ${cmd}. Try: dm, ask, assign, status, data, send, roster, busy, activity, memory, quit`);
    }

    rl.prompt();
  });
}

// ── Structured Message Handler ──────────────────────────────

function handleIncomingDM(fromName, fromId, msg) {
  const type = msg.type || "text";

  switch (type) {
    case "text":
      console.log(`💬 DM from ${fromName}: ${msg.text || JSON.stringify(msg)}`);
      // Auto-respond to ping
      if ((msg.text || "").toLowerCase().startsWith("ping") && fromId && currentFleetTopic) {
        reply(fromId, { type: "text", text: `pong — ${config.name} here, alive and well 🟢` });
        console.log(`→ Auto-pong sent to ${fromName}`);
      }
      break;

    case "task_request":
      console.log(`📋 Task from ${fromName}: [${msg.task}] ${msg.description || ""}`);
      console.log(`   ref: ${msg.ref || "none"} | priority: ${msg.priority || "normal"} | deadline: ${msg.deadline || "none"}`);
      if (msg.payload) console.log(`   payload: ${JSON.stringify(msg.payload).slice(0, 200)}`);
      // Auto-acknowledge task
      if (fromId && currentFleetTopic) {
        reply(fromId, {
          type: "task_ack",
          ref: msg.ref,
          status: "accepted",
          agent: config.name,
          estimated_ms: 5000,
        });
        console.log(`→ Task acknowledged to ${fromName}`);
        // Simulate work then respond with result
        setTimeout(() => {
          reply(fromId, {
            type: "task_result",
            ref: msg.ref,
            status: "completed",
            agent: config.name,
            result: { summary: `${config.name} completed task: ${msg.task}`, data: msg.payload },
          });
          console.log(`→ Task result sent to ${fromName}`);
        }, 2000);
      }
      break;

    case "task_ack":
      console.log(`✅ Task ACK from ${fromName}: ref=${msg.ref} status=${msg.status} est=${msg.estimated_ms}ms`);
      break;

    case "task_result":
      console.log(`📦 Task Result from ${fromName}: ref=${msg.ref} status=${msg.status}`);
      console.log(`   result: ${JSON.stringify(msg.result).slice(0, 300)}`);
      break;

    case "query":
      console.log(`❓ Query from ${fromName}: ${msg.question}`);
      if (msg.context) console.log(`   context: ${JSON.stringify(msg.context).slice(0, 200)}`);
      // Auto-respond with capabilities
      if (fromId && currentFleetTopic) {
        reply(fromId, {
          type: "query_response",
          ref: msg.ref,
          agent: config.name,
          answer: `I'm ${config.name} with capabilities: ${config.capabilities.join(", ")}. Ask me anything in those domains.`,
          confidence: 0.9,
        });
      }
      break;

    case "query_response":
      console.log(`💡 Answer from ${fromName}: ${msg.answer}`);
      if (msg.confidence) console.log(`   confidence: ${(msg.confidence * 100).toFixed(0)}%`);
      break;

    case "data":
      console.log(`📊 Data from ${fromName}: format=${msg.format || "json"} size=${JSON.stringify(msg.payload).length}b`);
      if (msg.label) console.log(`   label: ${msg.label}`);
      console.log(`   payload: ${JSON.stringify(msg.payload).slice(0, 300)}`);
      break;

    case "broadcast_request":
      console.log(`📢 ${fromName} asks fleet broadcast: [${msg.kind}] ${msg.description}`);
      // Relay as activity broadcast if requested
      if (currentFleetTopic && msg.relay) {
        pushChannel(currentFleetTopic, "activity:broadcast", {
          payload: { kind: msg.kind || "relayed", description: `[via ${fromName}] ${msg.description}`, tags: msg.tags || ["relayed"] }
        });
      }
      break;

    case "status_request":
      console.log(`📡 Status request from ${fromName}`);
      if (fromId && currentFleetTopic) {
        reply(fromId, {
          type: "status_response",
          agent: config.name,
          state: config.state,
          framework: config.framework,
          capabilities: config.capabilities,
          uptime_ms: Date.now() - startTime,
          timestamp: new Date().toISOString(),
        });
      }
      break;

    case "status_response":
      console.log(`📡 Status from ${fromName}: state=${msg.state} uptime=${formatMs(msg.uptime_ms)} caps=[${(msg.capabilities||[]).join(",")}]`);
      break;

    default:
      console.log(`📨 DM from ${fromName} [${type}]: ${JSON.stringify(msg).slice(0, 300)}`);
  }
}

function reply(toAgentId, message) {
  if (!currentFleetTopic) return;
  pushChannel(currentFleetTopic, "direct:send", {
    payload: { to: toAgentId, message }
  });
}

function formatMs(ms) {
  if (!ms) return "?";
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m${s % 60}s`;
  return `${Math.floor(s / 3600)}h${Math.floor((s % 3600) / 60)}m`;
}

const startTime = Date.now();

// ── Start ───────────────────────────────────────────────────
connect();
