// Renames a tab outside the hook's filter and fails with the error's name.
arch.events.on("pageLoaded", async () => {
  try {
    await arch.tabs.rename("00000000-0000-0000-0000-0000000000C2", "Name");
  } catch (error) {
    throw new Error("refused: " + error.message);
  }
  throw new Error("renamed");
});
