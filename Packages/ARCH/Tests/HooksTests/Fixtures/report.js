// Reports what the script receives: the event, the tabs it lists, and each probe tab it asks for, as JSON in the message of the error it throws, which the tests read from the failed run.
const probes = [
  "00000000-0000-0000-0000-0000000000C1",
  "00000000-0000-0000-0000-0000000000C2",
  "00000000-0000-0000-0000-0000000000C3",
  "00000000-0000-0000-0000-0000000000C4",
  "00000000-0000-0000-0000-0000000000C5",
];

arch.events.on("pageLoaded", async (event) => {
  const report = { event, list: await arch.tabs.list(), get: {} };
  for (const id of probes) report.get[id] = await arch.tabs.get(id);
  throw new Error(JSON.stringify(report));
});
