#!/usr/bin/env node
/**
 * RingForge Agent Connect Script
 * 
 * Connects to a RingForge hub as an agent via Phoenix Channels WebSocket.
 * 
 * Usage:
 *   node connect_agent.js --url wss://ringforge.wejoona.com --key rf_live_XXX --name "Argus Key"
 *   
 * Or with env vars:
 *   RINGFORGE_URL=wss://ringforge.wejoona.com RINGFORGE_KEY=rf_live_XXX node connect_agent.js
 * 
 * Requires: npm install ws (or use Bun/Deno which have built-in WebSocket)
 */

const WebSocket = require("ws");

// ── Config ──────────────────────────────────────────────────
const config = {
  url: process.env.RINGFORGE_URL || process.argv.find((a, i) => process.argv[i - 1] === "--url") || "wss://ringforge.wejoona.com",
  apiKey: process.env.RINGFORGE_KEY || process.argv.find((a, i) => process.argv[i - 1] === "--key") || "",
  name: process.env.RINGFORGE_NAME || process.argv.find((a, i) => process.argv[i - 1] === "--name") || "agent-" + Math.random().toString(36).slice(2, 8),
  framework: process.env.RINGFORGE_FRAMEWORK || process.argv.find((a, i) => process.argv[i - 1] === "--framework") || "openclaw",
  capabilities: (process.env.RINGFORGE_CAPS || process.argv.find((a, i) => process.argv[i - 1] === "--caps") || "chat,code,search").split(","),
  state: "online",
};

if (!config.apiKey) {
  console.error("❌ No API key. Use --key rf_live_XXX or set RINGFORGE_KEY");
  process.exit(1);
}

// ── Phoenix Channel Protocol ────────────────────────────────
let refCounter = 0;
let ws;
let heartbeatInterval;
let joinRef;

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
          onJoined(topic, payload.response);
        }
      } else if (payload.status === "error") {
        console.error("❌ Error:", topic, payload.response);
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
      console.log(`💬 DM from ${p.from?.name || p.from?.agent_id}: ${p.message?.text || JSON.stringify(p.message)}`);
    } else if (event === "system:quota_warning") {
      console.log("⚠️  Quota warning:", JSON.stringify(payload));
    } else if (topic === "phoenix" && event === "phx_reply") {
      // heartbeat ack, ignore
    } else {
      console.log(`📨 ${topic} :: ${event}`, JSON.stringify(payload).slice(0, 200));
    }
  });

  ws.on("close", (code, reason) => {
    console.log(`🔌 Disconnected (${code}): ${reason || "no reason"}`);
    clearInterval(heartbeatInterval);
    // Reconnect after 3s
    setTimeout(connect, 3000);
  });

  ws.on("error", (err) => {
    console.error("❌ WebSocket error:", err.message);
  });
}

async function resolveFleetAndJoin() {
  // Use the admin API to resolve fleet_id, or just try to discover it
  // via an HTTP call to /api/health or similar.
  // 
  // Simplest: the API key's fleet is embedded. Let's query the admin API.
  try {
    const http = require("https");
    const url = `${config.url.replace("wss://", "https://").replace("ws://", "http://")}/api/keys/resolve?key=${encodeURIComponent(config.apiKey)}`;
    
    // If there's no resolve endpoint, we need to know the fleet_id.
    // Let's just use the fleet_id from the environment or try common ones.
    const fleetId = process.env.RINGFORGE_FLEET_ID || "";
    
    if (fleetId) {
      joinFleet(fleetId);
    } else {
      // Try to get fleet from /api/fleets with the key
      // For now, let's just print instructions
      console.log("ℹ️  Fleet ID not specified. Trying to discover...");
      
      // The Phoenix socket already has fleet_id in assigns after connect.
      // We can try joining with a placeholder and catch the error,
      // or better: make a quick HTTP request.
      
      // Let's try the admin endpoint
      const adminUrl = config.url.replace("wss://", "https://").replace("ws://", "http://");
      const resp = await fetch(`${adminUrl}/api/admin/fleets`, {
        headers: { "x-api-key": config.apiKey }
      });
      
      if (resp.ok) {
        const data = await resp.json();
        if (data.fleets && data.fleets.length > 0) {
          joinFleet(data.fleets[0].id);
          return;
        }
      }
      
      // Fallback: the socket already knows our fleet. We need a way to discover it.
      // Let's add a system channel for this.
      console.log("⚠️  Could not auto-discover fleet ID.");
      console.log("   Pass it via: --fleet <fleet-id> or RINGFORGE_FLEET_ID=<id>");
      console.log("   Find it in the dashboard Settings page.");
    }
  } catch (err) {
    // fetch might not exist in older Node. Use fleet from env.
    const fleetId = process.env.RINGFORGE_FLEET_ID || process.argv.find((a, i) => process.argv[i - 1] === "--fleet");
    if (fleetId) {
      joinFleet(fleetId);
    } else {
      console.error("❌ Cannot discover fleet ID. Pass --fleet <id>");
    }
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
  console.log("🚀 Connected to mesh! Interactive commands:");
  console.log("   Type in terminal:");
  console.log("   busy <task>     — set state to busy with task");
  console.log("   online          — set state to online");
  console.log("   away            — set state to away");
  console.log("   activity <desc> — broadcast an activity");
  console.log("   dm <agent> <msg>— send direct message");
  console.log("   roster          — request roster");
  console.log("   quit            — disconnect");
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
        const msg = args.slice(1).join(" ");
        if (!toAgent || !msg) {
          console.log("Usage: dm <agent_id> <message>");
        } else {
          pushChannel(topic, "direct:send", {
            payload: { to: toAgent, message: { text: msg } }
          });
          console.log(`→ DM sent to ${toAgent}`);
        }
        break;

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
        console.log(`Unknown command: ${cmd}. Try: busy, online, away, activity, task, done, dm, roster, memory, quit`);
    }

    rl.prompt();
  });
}

// ── Start ───────────────────────────────────────────────────
connect();
