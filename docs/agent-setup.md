# Use 00Food with your AI agent

00Food is an iPhone food log built for you and your AI agent. There is no built-in food catalogue or bundled AI agent: your personal library grows from estimates you approve or foods you enter manually. Search covers that personal library.

## Recommended setup: ChatGPT Work

1. Sign in to 00Food with Apple, then open **Connect your agent** on the home screen or in Settings.
2. In ChatGPT Plugins, choose **Add custom MCP server** and enter `https://api.00food.com/mcp`. Sign in with the same Apple account and approve the requested food permissions. Connect or rescan the server so its tools and events are available.
3. Start a Work chat on ChatGPT web, or select Work and Cloud in the desktop app. Add your 00Food plugin to that chat.
4. Use **Copy agent instructions** in 00Food and paste the instructions into the chat. They tell the agent to check existing pending foods and subscribe to new estimate requests, clarifications, and food logs. The agent uses both the description and attached photo and proposes an estimate with an explanation. You review each proposal in the app before saving or logging it.
5. Return to 00Food and refresh connection status. **Connected** means that the account connection is authorized. The individual **subscribed** lines show currently unexpired event subscriptions; they do not guarantee when the agent will respond. Connecting alone does not subscribe to events.

For daily reviews, tell the agent you want them and approve the additional food/Health summary permissions when requested. Ask it to subscribe to `day.feedback_requested`. Enable **Request a daily review** in Settings for automatic requests, or request individual past days from the food log. The automatic setting uploads a completed day's food context and up to six earlier days of available Health totals the next time the app opens; it does not run the agent itself.

Daily-review context includes guidance to reflect on protein sources and overall diet variety as well as calories, produce and hydration. No protein grams or nutrient totals are measured, so the agent should keep this qualitative and acknowledge incomplete logs. The fruit/veg tracker stops at five: a completed goal means **at least five portions**. Health water is an uncapped recorded amount, which may be less than everything drunk; meeting the 2 L tracking goal does not imply intake stopped there. These explanations are included with each context response, including requests created before this change. Saved reviews are not rewritten automatically.

Reviews support light Markdown: short headings, bullet or numbered lists, bold/italic emphasis and web links. Agents receive this formatting guidance with each daily-review context. Keep reviews concise and avoid tables, HTML, images and code blocks.

Your AI service's availability, access requirements, and instructions affect responses. Current OpenAI instructions are at [MCP Events](https://developers.openai.com/plugins/build/mcp-events) and [plugin quickstart](https://developers.openai.com/plugins/quickstart).

## Other compatible agents

Connect the remote MCP server and ask your agent to check pending foods or daily review requests. Agents without webhook events can catch up on new foods and clarifications with `list_food_events`. The webhook Events implementation currently accepts ChatGPT/OpenAI callback hosts only; support for other webhook hosts needs a separate integration change. Do not assume that any MCP connection supports automatic event responses.

You can always log foods manually and reuse saved foods. Estimate requests can be saved offline and sent when the app reconnects; agent responses need a working connection and an available agent.
