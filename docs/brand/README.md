# 00Food identity

**Your food log. Your AI agent.**

00Food is a food log built for you and your AI agent. Users bring their own compatible agent to estimate foods and help review their day. They approve estimates and build a personal reusable food library. Say “no built-in food catalogue,” rather than “no database”: 00Food stores users’ saved foods. Manual logging is always available.

The App Store name is **00Food: AI Food Companion**, with subtitle **Bring your own AI agent**. Keep these promises consistent in the sign-in screen, first-use guidance, empty states, and marketing copy. Prefer “your agent” to wording that implies a bundled model or automatic estimation without setup. Explain MCP Events through its benefit: the agent can respond to estimate and review requests without being asked to check each time. Recommend ChatGPT Work for the current webhook integration; do not promise equivalent event support in every MCP client.

Store copy is maintained in [app-store.json](app-store.json). Setup and compatibility are documented in [the agent guide](../agent-setup.md).

00Food keeps the 00Widget and 00Todo two-card agent, white fedora, slashed-zero eyes, blue edge, and teal accent. Two horizontal, gently curved utensils form a stacked smile: a knife above a fork, with no plate. A warm coral field distinguishes its icon from its siblings. The wordmark uses the same blue `00` and Avenir Next typography.

The generator uses the approved 00Food masters in `sources/` and produces the app icon, in-app mark, transparent marks, wordmarks, and preview. The icon master is the selected stacked-smile preview; its transparent companion was created with the built-in image generation tool. Both are saved here so regeneration preserves the approved artwork. Run `python3 docs/brand/generate.py` from the repository root. The original 00Widget reference masters remain in `sources/` under their separate license; the 00Food masters and derived assets use this directory's brand license.

![00Food brand preview](brand-preview.png)
