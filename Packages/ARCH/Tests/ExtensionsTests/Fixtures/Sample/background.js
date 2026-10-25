// Sets the action's badge in each tab whose page the content script marked.
browser.runtime.onMessage.addListener((message, sender) => {
  if (message.marked && sender.tab) browser.action.setBadgeText({ text: "1", tabId: sender.tab.id });
});
