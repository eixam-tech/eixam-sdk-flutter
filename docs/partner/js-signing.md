# Identity Signing (JS)

To use the SDK, the backend must generate a `userHash` by signing the user's **External ID** with the application's **Secret Key**.

### Specifications
*   **Algorithm**: HMAC-SHA256
*   **Key**: `secretKey` (App Secret)
*   **Message**: `externalUserId` (User ID)
*   **Output Format**: Hexadecimal

## Node.js

```javascript
const crypto = require('crypto');

function generateUserHash(secretKey, userId) {
  return crypto
    .createHmac('sha256', secretKey)
    .update(userId)
    .digest('hex');
}

// Usage
const hash = generateUserHash('your_secret_key', 'user_123');
```

## Browser (Web Crypto API)

> [!CAUTION]
> The `secretKey` **must never** be exposed in the frontend. Use this code only in trusted environments or for testing purposes.

```javascript
async function generateUserHash(secretKey, userId) {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw', 
    enc.encode(secretKey),
    { name: 'HMAC', hash: 'SHA-256' }, 
    false, 
    ['sign']
  );

  const signature = await crypto.subtle.sign('HMAC', key, enc.encode(userId));
  
  return Array.from(new Uint8Array(signature))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');
}
```
