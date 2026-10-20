# Privacy Policy — THN

_Last updated: 20 October 2026_

THN ("the app") is a reader for Hacker News, made by Henrik Petersen. This policy explains
what happens to your data when you use it. The short version: **no advertising, no
tracking across other apps, nothing linked to your identity.** The App Store version
collects anonymous usage statistics, which you can switch off.

## What the app does not do

- No advertising, and no tracking across other apps or websites.
- No accounts on any server run by the developer.
- No data is sold.

## Anonymous usage statistics (App Store version)

To learn which features are used, the App Store version sends anonymous usage events to
[PostHog](https://posthog.com), hosted in the European Union. An event records:

- what happened, for example "opened a story", "voted", "searched" or "changed section";
- the app version, iOS version, device type (iPhone or iPad) and language setting;
- whether you subscribe and to which plan, and subscription events (started, renewed,
  ended, restored) with the plan, price, currency and App Store country;
- an approximate location (country and city) that PostHog derives from your IP address;
- a random identifier created when the app is installed.

Events never include your Hacker News username, password or cookie, what you read, search
for or write, or any other content. They are not linked to your identity and no person
profiles are created. You can switch statistics off at any time under **Share anonymous
usage statistics** on the account screen (the person icon). Copies of THN built from the
public source code contain no analytics.

## Hacker News

- Stories, comments and profiles are loaded from the public Hacker News API
  (`hacker-news.firebaseio.com`), the Algolia HN Search API (`hn.algolia.com`) and
  `news.ycombinator.com`.
- When you sign in, your username and password are sent **only** to `news.ycombinator.com`,
  exactly as the Hacker News website does. The app stores only the resulting sign-in cookie,
  in your device's Keychain. Signing out deletes it.
- Votes, comments, submissions and profile changes go directly to Hacker News and are subject
  to [Y Combinator's privacy policy](https://www.ycombinator.com/legal/#privacy).

## Articles and preview images

Linked articles open in an in-app browser, and the app fetches each article's preview image
from its website. Those sites see a normal web request from your device and have their own
privacy policies.

## Purchases

Any in-app purchases are processed by Apple. The developer receives no payment details or
personal information. See
[Apple's privacy policy](https://www.apple.com/legal/privacy/).

## On your device

The app stores small preferences locally on your device. Deleting the app removes them.

## Contact

Questions: open an issue at <https://github.com/hpetersen/THN/issues>.
