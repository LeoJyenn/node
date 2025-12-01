const { spawn } = require("child_process");

const apps = [
  {
    name: "h2",
    binaryPath: "/home/container/h2/h2", 
    args: ["server", "-c", "/home/container/h2/config.yaml"]
  },
  {
    name: "nz",
    binaryPath: "/home/container/nz/nz",
    args: ["-c", "/home/container/nz/config.yaml"]
  }
];

function runProcess(app) {
  const child = spawn(app.binaryPath, app.args, { stdio: "inherit" });

  child.on("exit", (code) => {
    console.log(`[EXIT] ${app.name} exited with code: ${code}`);
    console.log(`[RESTART] Restarting ${app.name}...`);
    setTimeout(() => runProcess(app), 3000);
  });
}

function main() {
  try {
    for (const app of apps) {
      runProcess(app);
    }
  } catch (err) {
    console.error("[ERROR] Startup failed:", err);
    process.exit(1);
  }
}

main();
