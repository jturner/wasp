import { stripTrailingSlash } from '../universal/url.js';
const apiUrl = stripTrailingSlash(import.meta.env.REACT_APP_API_URL) || 'http://localhost:3001';
// PUBLIC API
export const config = {
    apiUrl,
};
//# sourceMappingURL=config.js.map