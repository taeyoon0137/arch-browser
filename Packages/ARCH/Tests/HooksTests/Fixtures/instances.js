// Counts the runs of this start of the script and fails with the count, which tells a new start from an old one. For a page whose address has "hang" in it, the run never settles; the kept resolvers keep its promise reachable, since WebKit fails a call whose promise nothing can settle any more.
let runs = 0;
const unanswered = [];

arch.events.on("pageLoaded", (event) => {
  runs += 1;
  if (event.tab.url?.includes("hang")) return new Promise((resolve) => unanswered.push(resolve));
  throw new Error(String(runs));
});
