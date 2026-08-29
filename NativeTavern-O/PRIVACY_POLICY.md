# Privacy Policy for NativeTavern

**Last Updated: August 18, 2026**

## Overview

NativeTavern is a local-first AI character chat application. NativeTavern does
not operate an AI proxy and does not collect or store your conversations on
NativeTavern servers. When you choose a remote AI feature, the app sends the
data required for that feature directly from your device to the provider or
endpoint you configured.

This policy explains what stays on your device, what may leave your device at
your request, who may receive it, and how to control that sharing.

## Data Stored on Your Device

NativeTavern stores the following data locally:

- Characters, personas, system instructions, lorebooks, world information,
  memories, Data Bank content, and tool configuration
- Conversations, messages, bookmarks, and chat history
- Images, backgrounds, sprites, Live2D/Spine assets, audio, and generated media
- App preferences, provider configuration, API credentials, and backups
- Local capability and external-call diagnostics, which record destinations,
  data categories, status, and timing but not request content or API keys

This local data remains on your device unless you initiate an export, cloud
backup, URL import, or remote AI request.

## Remote AI Data Sharing

### Consent and control

Before NativeTavern permits remote AI requests, the app displays a disclosure
that identifies the data categories and supported recipients. You may choose
either **Allow remote AI** or **Use local AI only**.

Your choice is saved on your device. You can withdraw or restore permission at
any time under **Settings > Remote AI data sharing**. When permission is off,
NativeTavern blocks remote AI requests before they leave the device. Local and
private-network AI endpoints remain available. A materially changed disclosure
will require a new choice.

### Data that may be sent

The exact data depends on the feature you use:

- **Chat and text generation:** your current message, relevant chat history,
  character and persona content, system instructions, enabled lorebook/world
  information, memory or Data Bank excerpts, and enabled tool definitions or
  tool inputs
- **Embeddings and semantic search:** document text or excerpts selected for
  embedding
- **Image generation:** prompts, generation settings, and any source or
  reference image you provide
- **Speech to text:** recorded audio and selected language/model settings
- **Text to speech:** text to synthesize and selected voice/model settings;
  generated audio is returned to your device
- **Authentication and request metadata:** your API credential, model name,
  request settings, IP address, and standard network metadata required to make
  and authenticate the connection

NativeTavern sends this data only when you invoke or enable the corresponding
remote feature. NativeTavern does not use it for advertising or sell it.

### Recipients

Depending on the provider and endpoint you configure, data may be sent directly
to:

- Anthropic
- An OAI Compatible endpoint you configure
- OpenRouter
- Google Gemini
- DeepSeek
- Alibaba Cloud Qwen (DashScope)
- SiliconFlow
- Moonshot AI / Kimi
- Z.AI
- MiniMax
- Cohere
- ElevenLabs
- Microsoft Azure Speech
- Volcengine
- NovelAI
- Pollinations
- A self-hosted or custom endpoint whose address you enter

The active provider and endpoint are shown in the relevant AI configuration
screen. If you enter a custom endpoint, the operator of that endpoint is the
recipient and is responsible for its privacy and security practices.

Remote providers process data under their own terms and privacy policies. The
supported providers publish privacy and security commitments intended to
protect data they receive. NativeTavern connects directly to the provider using
your account or API credential and does not control provider-side retention,
training, or deletion. Review the selected provider's privacy policy and account
data controls before use. Do not use a provider or custom endpoint whose
protections do not meet your requirements.

## Cloud Backup

Cloud backup is optional and user initiated. If you choose Google Drive or an
available Apple/iCloud storage location, the selected backup file and the
account information needed for authentication are handled by Google or Apple
under their respective privacy policies. NativeTavern does not receive a copy
of your backup through its own servers. You can sign out, delete cloud backups,
or use local export instead.

## URL Imports and External Links

When you request an import from a URL or open an external link, the destination
website receives the requested URL and normal network metadata such as your IP
address and user agent. Imported character data is stored locally after it is
downloaded. The destination website's privacy policy applies to that request.

## Data Retention and Deletion

- Local data remains until you delete it in the app or uninstall the app.
- A local export remains wherever you save or share it.
- A cloud backup remains until you delete it from the selected cloud provider.
- Remote AI providers retain or delete transmitted data according to their
  policies and your provider account settings.
- NativeTavern cannot retrieve or delete data held by a provider because the
  request is made directly with your provider account or custom endpoint.

## Security

NativeTavern relies on device security for locally stored data and keeps API
credentials on the device except when sending them directly to authenticate a
request. Use HTTPS for remote custom endpoints, protect device access, and do
not share exported backups or API credentials with untrusted parties.

## Permissions

NativeTavern may request:

- **Camera or photo access:** to select or capture character and background
  images, including location metadata that may be embedded in a selected photo
- **Microphone and speech recognition:** for speech features you invoke
- **Files or storage:** to import, export, and back up your data
- **Network access:** for remote AI, cloud backup, URL import, external links,
  and provider authentication

Permissions are requested when needed and can be changed in system settings.

## Your Choices and Rights

You can:

- View, edit, export, and delete locally stored content
- Disable remote AI data sharing while continuing to use local endpoints
- Change or remove provider credentials and custom endpoints
- Delete cloud backups or disconnect a cloud account
- Revoke operating-system permissions

Depending on your jurisdiction, you may also have legal rights concerning data
held by a remote provider. Submit those requests directly to that provider.

## Children's Privacy

NativeTavern is not directed to children under 13 and does not knowingly
collect their personal data. Users must meet the minimum age required by their
jurisdiction and by each remote provider they choose.

## Changes to This Policy

We may update this policy when features or data practices change. We will update
the date above and require a new in-app choice before remote AI sharing when a
change materially affects the disclosure.

## Contact

Questions or privacy requests may be sent to:

- Email: support@nativetavern.com
- Discord: https://discord.com/invite/URQvW2FvZa
