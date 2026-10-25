// The sample plugin's page script: it sends the page's title to the plugin and adds the plugin's name to the title it gets back, so that the tab's row shows the round trip.
arch.send({ title: document.title }).then((reply) => {
  document.title = `${reply.echo.title} · Sample`;
});
