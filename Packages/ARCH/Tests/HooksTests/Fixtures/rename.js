// Renames the event's tab with a name of two lines, and fails with "notTaken" when the tab does not take it.
arch.events.on("pageLoaded", async (event) => {
  const took = await arch.tabs.rename(event.tab.id, "  Named  \nsecond line");
  if (!took) throw new Error("notTaken");
});
