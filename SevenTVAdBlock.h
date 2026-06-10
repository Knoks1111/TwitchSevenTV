/*
 * SevenTVAdBlock.h
 * Clés NSUserDefaults et constantes pour le Stream Proxy / AdBlock intégré.
 */

#pragma once

// ── Stream Proxy ──────────────────────────────────────────────────────────────
#define kTCStreamProxyEnabled            @"TCDBGStreamProxyEnabled"
#define kTCStreamProxyUseResourceLoader  @"TCDBGStreamProxyUseResourceLoader"
#define kTCStreamProxyFallbackEnabled    @"TCDBGStreamProxyFallbackEnabled"
#define kTCStreamProxySanitizeM3U8       @"TCDBGStreamProxySanitizeM3U8"
#define kTCStreamProxyAnyM3U8Host        @"TCDBGStreamProxyAnyM3U8Host"
#define kTCStreamProxyGraphQLTokenOps    @"TCDBGStreamProxyGraphQLTokenOps"
#define kTCStreamProxyURL                @"TCDBGStreamProxyURL"
#define kTCStreamProxySavedList          @"TCDBGStreamProxySavedList"
#define kTCStreamProxyLocalEnabled       @"TCDBGStreamProxyLocalEnabled"
#define kTCStreamProxyLocalPort          @"TCDBGStreamProxyLocalPort"
#define kTCStreamProxyTestTimeout        @"TCDBGStreamProxyTestTimeout"

// ── Live Stream Control ───────────────────────────────────────────────────────
#define kTCLiveAutoCollectChannelPoints  @"TCDBGLiveAutoCollectChannelPoints"
#define kTCAdsBypassIndicatorEnabled     @"TCAdsBypassIndicatorEnabled"
#define kTCAdsBypassIndicatorTagEnabled  @"TCAdsBypassIndicatorTagEnabled"

// ── Disable Ads ───────────────────────────────────────────────────────────────
#define kTCAdsDisabled                   @"TCDBGAdsDisabled"

// ── Blocked / Excluded URLs ───────────────────────────────────────────────────
#define kTCBlockedURLList                @"TCDBGBlockedURLList"
#define kTCExcludedURLList               @"TCDBGExcludedURLList"

// ── Proxy Templates ───────────────────────────────────────────────────────────
static NSArray<NSDictionary *> *S7TVProxyTemplates(void) {
    return @[
        @{ @"title": @"Live Proxy",     @"url": @"https://proxy.example/live/$channel?allow_source=true&allow_audio_only=true" },
        @{ @"title": @"Live Proxy Alt", @"url": @"https://proxy.example/live/$channel?allow_source=true&allow_audio_only=true&fast_bread=true" },
        @{ @"title": @"Generic URL",    @"url": @"https://proxy.example/proxy?url=$url" },
        @{ @"title": @"Local Loopback", @"url": @"http://127.0.0.1:9595/proxy?url=$url" },
    ];
}
