// The sample plugin's background script, which the plugin tests install and run.

// The commands this start of the background script has run, which tells a new start from an old one.
let runs = 0;

arch.commands.onRun("remember", async (invocation) => {
  runs += 1;
  const label = await arch.settings.get("label");
  await arch.storage.set("remembered", { label, url: invocation.tab?.url ?? null, link: invocation.linkUrl ?? null, runs });
  await arch.ui.setBadge("remembered", String(runs));
});

// Records what the sandbox and the grant let the script do.
arch.commands.onRun("probe", async () => {
  const outcome = async (attempt) => {
    try {
      await attempt();
      return "allowed";
    } catch (error) {
      return error.name === "Error" ? error.message : error.name;
    }
  };
  await arch.storage.set("probe", {
    eval: await outcome(() => eval("1")),
    fetch: await outcome(() => fetch("https://example.org/")),
    // The content security policy and the rule list do not cover WebRTC, so neither the document nor a frame it adds may have it.
    webRTC: [window, document.documentElement.appendChild(document.createElement("iframe")).contentWindow].map((realm) => typeof realm.RTCPeerConnection).join(),
    copy: await outcome(() => arch.ui.copy("text")),
    reservedKey: await outcome(() => arch.storage.set("arch.setting:label", 1)),
    removed: await outcome(async () => {
      await arch.storage.set("removable", 1);
      await arch.storage.set("removable");
      if ((await arch.storage.keys()).includes("removable")) throw new Error("kept");
    }),
  });
});

// Never answers, as a hung background script. The kept resolvers keep each promise reachable; WebKit fails a call whose promise nothing can settle any more.
const unanswered = [];
arch.commands.onRun("wait", () => new Promise((resolve) => unanswered.push(resolve)));

arch.pages.onMessage((message) => ({ echo: message.body, frame: message.frameUrl, tab: message.tab.id }));
