// Shows the address of the active tab of the current window, and puts it in the title, where a test can read it.
browser.tabs.query({ active: true, currentWindow: true }).then((tabs) => {
  const address = tabs[0]?.url ?? "no tab";
  document.getElementById("address").textContent = address;
  document.title = "Sample popup: " + address;
});
