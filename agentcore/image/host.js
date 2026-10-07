// AgentCore V2 snapshots the container after its first healthy /ping (within
// 120 seconds); start idle with no session state. Each new session restores it.
// Invocation starts the one-shot coder; the workflow polls GitHub for its PR.
const http = require("http");
const fs = require("fs");
const { spawn } = require("child_process");

const PORT = Number(process.env.PORT || 8080);
const TOKEN_PATH = "/tmp/secrets/gh-token";
const MAX_BODY = 64 * 1024;
let busy = false;

function reply(res, status, value) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(value));
}

const server = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/ping") {
    return reply(res, 200, { status: busy ? "HealthyBusy" : "Healthy" });
  }
  if (req.method !== "POST" || req.url !== "/invocations") {
    return reply(res, 404, { error: "not found" });
  }
  if (busy) return reply(res, 409, { error: "coder already running" });
  const chunks = [];
  let bytes = 0;
  req.on("data", (chunk) => {
    bytes += chunk.length;
    if (bytes > MAX_BODY) {
      reply(res, 413, { error: "payload too large" });
      req.removeAllListeners("data");
      req.resume();
    } else {
      chunks.push(chunk);
    }
  });
  req.on("end", () => {
    if (res.writableEnded) return;
    if (busy) return reply(res, 409, { error: "coder already running" });
    let d;
    try { d = JSON.parse(Buffer.concat(chunks).toString("utf8")); }
    catch { return reply(res, 400, { error: "invalid JSON" }); }
    if (!d || typeof d !== "object" || Array.isArray(d) ||
        !["ghToken", "repo", "issueNumber"].every((key) =>
          ["string", "number"].includes(typeof d[key]) && String(d[key]).length > 0)) {
      return reply(res, 400, { error: "missing invocation fields" });
    }
    try {
      fs.mkdirSync("/tmp/secrets", { recursive: true, mode: 0o700 });
      fs.writeFileSync(TOKEN_PATH, String(d.ghToken), { mode: 0o600 });
      fs.chmodSync(TOKEN_PATH, 0o600);
      const env = {
        ...process.env,
        DF_ISSUE_NUMBER: String(d.issueNumber),
        DF_REPO: String(d.repo),
        DF_BRANCH: String(d.branch || `df/issue-${d.issueNumber}`),
        DF_BASE_BRANCH: String(d.baseBranch || "main"),
        DF_ISSUE_TITLE: String(d.issueTitle || ""),
        DF_ITERATE_NOTE_B64: String(d.iterateNoteB64 || ""),
        DF_ITERATE_NOTE: String(d.iterateNote || ""),
        DF_SUBSTRATE: "Amazon Bedrock AgentCore Runtime microVM",
        USE_BEDROCK: "1",
        AWS_REGION: String(d.region || process.env.AWS_REGION || "us-west-2"),
        WORKSPACE: "/tmp/workspace",
        GH_TOKEN_PATH: TOKEN_PATH,
      };
      const child = spawn("node", ["/app/entrypoint.js"], {
        env, detached: true, stdio: "inherit",
      });
      busy = true;
      child.on("error", (err) => { busy = false; console.error("[agentcore] coder spawn failed:", err.message); });
      child.on("exit", (code) => { busy = false; console.log(`[agentcore] coder exited code=${code}`); });
      child.unref();
      reply(res, 202, { accepted: true });
    } catch (err) {
      console.error("[agentcore] coder setup failed:", err.message);
      reply(res, 500, { error: "coder setup failed" });
    }
  });
});
server.listen(PORT, "0.0.0.0", () => console.log(`[agentcore] listening on :${PORT}`));
