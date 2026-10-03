/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'standalone',
  experimental: {
    instrumentationHook: true,
    serverComponentsExternalPackages: ['@tavily/core', 'pg', 'mermaid'],
  },
};

module.exports = nextConfig;
