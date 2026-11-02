self.addEventListener("push", (event) => {
  let data = {};

  try {
    data = event.data ? event.data.json() : {};
  } catch {
    data = {
      body: event.data?.text() || "Новое сообщение"
    };
  }

  const notificationData = data.data || data;

  const title = data.title || "MIRA";
  const body =
    data.body ||
    data.message ||
    "У вас новое сообщение";

  const conversationId =
    notificationData.conversation_id ||
    notificationData.conversationId ||
    "";

  let targetUrl =
    notificationData.url || "/mira/";

  if (
    !notificationData.url &&
    conversationId
  ) {
    targetUrl =
      "/mira/?conversation=" +
      encodeURIComponent(conversationId);
  }

  event.waitUntil(
    self.registration.showNotification(title, {
      body,
      icon: "/mira/icon-192.png",
      badge: "/mira/icon-192.png",
      data: {
        url: targetUrl
      }
    })
  );
});


self.addEventListener("notificationclick", (event) => {
  event.notification.close();

  const targetUrl =
    event.notification.data?.url || "/mira/";

  event.waitUntil(
    clients.matchAll({
      type: "window",
      includeUncontrolled: true
    }).then(async (windowClients) => {
      for (const client of windowClients) {
        if (client.url.startsWith(self.location.origin)) {
          try {
            await client.navigate(targetUrl);
            return client.focus();
          } catch (error) {
            console.error("MIRA notification click:", error);
          }
        }
      }

      return clients.openWindow(targetUrl);
    })
  );
});