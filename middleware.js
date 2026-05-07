export default async function middleware(request) {
  const url = new URL(request.url);

  if (url.pathname === '/' || url.pathname === '') {
    const dreamflowUrl = 'https://f9b440d4-a190-4364-82e5-343bf3cbc027.share.dreamflow.cloud/';
    const response = await fetch(dreamflowUrl, {
      headers: request.headers,
    });
    const contentType = response.headers.get('content-type') || 'text/html';

    if (contentType.includes('text/html')) {
      const html = await response.text();
      const metaTag = '<meta name="fo-verify" content="becbc85a-7e8a-4d4d-8e5e-882c3d6b5ce3">';
      const modifiedHtml = html.replace('<head>', '<head>\n' + metaTag);
      return new Response(modifiedHtml, {
        status: response.status,
        headers: { 'content-type': contentType },
      });
    }

    return response;
  }
}

export const config = {
  matcher: '/',
};
