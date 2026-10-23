// Long-lived offscreen document keeps the extension worker alive while automation runs.
chrome.runtime.onMessage.addListener(() => {});
