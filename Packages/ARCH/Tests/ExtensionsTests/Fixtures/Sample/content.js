// Marks the page, so that a test can see that the content script ran, and tells the background script which tab it ran in.
document.documentElement.dataset.sampleExtension = "ran";
browser.runtime.sendMessage({ marked: location.href });
