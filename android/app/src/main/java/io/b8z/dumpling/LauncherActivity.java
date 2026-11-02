package io.b8z.dumpling;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.graphics.Insets;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.util.Log;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.webkit.ConsoleMessage;
import android.webkit.CookieManager;
import android.webkit.JavascriptInterface;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.Toast;
import android.window.OnBackInvokedDispatcher;

import androidx.webkit.WebViewAssetLoader;

import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

/**
 * The home screen. launcher/index.html runs full screen in one WebView, with the wallpaper drawn live in
 * WebGL on the phone's GPU. When the page asks for an app it posts JSON to {@code window.dumplingShell}:
 * <ul>
 *   <li>{"open": url}: a second WebView fades in over the wallpaper; swipe up from the bottom strip, press
 *       Home or Back (with no page history left) to come home.</li>
 *   <li>{"android": package, "name": label}: starts that Android app ("settings" is the system Settings);
 *       Home brings it back here.</li>
 * </ul>
 * The page is the one in the repo's launcher/ folder, packed into the APK as assets and served from
 * https://appassets.androidplatform.net/assets/ so it is a secure origin, not file://.
 */
public final class LauncherActivity extends Activity {
    private static final String TAG = "Dumpling";
    private static final String HOME_URL = "https://appassets.androidplatform.net/assets/index.html#android";
    /** Debug builds only: load the page from somewhere else (android/deploy.sh live serves it from the Mac). */
    private static final String EXTRA_DEV_URL = "dev_url";
    private static final int VOID = 0xFF04060C;
    private static final int EDGE_DP = 36;      // the strip under a web app that takes the swipe home
    private static final int SWIPE_DP = 56;     // how far up the swipe has to go
    private static final int REQ_FILE = 1;

    private FrameLayout root;
    private WebView home, appView;
    private FrameLayout edge;
    private WebViewAssetLoader assets;
    private String homeUrl = HOME_URL;
    private boolean debuggable, appShown, clearAppHistory;
    private Insets bars = Insets.NONE, ime = Insets.NONE;
    private ValueCallback<Uri[]> fileCallback;

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        debuggable = (getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0;
        WebView.setWebContentsDebuggingEnabled(debuggable);    // chrome://inspect on the Mac, over USB
        assets = new WebViewAssetLoader.Builder()
                .addPathHandler("/assets/", new WebViewAssetLoader.AssetsPathHandler(this))
                .build();
        String dev = devUrl(getIntent());
        if (dev != null) homeUrl = dev;

        root = new FrameLayout(this);
        root.setBackgroundColor(VOID);
        home = newHome();
        root.addView(home, full());
        appView = newAppView();
        appView.setVisibility(View.GONE);
        root.addView(appView, full());
        edge = newEdge();
        edge.setVisibility(View.GONE);
        root.addView(edge, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(EDGE_DP), Gravity.BOTTOM));
        root.setOnApplyWindowInsetsListener((v, in) -> {
            bars = in.getInsets(WindowInsets.Type.systemBars());
            ime = in.getInsets(WindowInsets.Type.ime());
            layoutApp();
            return WindowInsets.CONSUMED;
        });
        setContentView(root);
        getWindow().setDecorFitsSystemWindows(false);

        if (Build.VERSION.SDK_INT >= 33) {
            getOnBackInvokedDispatcher().registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, this::onBack);
        }
        Log.i(TAG, "home " + homeUrl);
        home.loadUrl(homeUrl);
        applyBars();
    }

    // ------------------------------------------------------------------------------------------ web views

    private WebView newWebView() {
        WebView w = new WebView(this);
        w.setBackgroundColor(VOID);
        w.setOverScrollMode(View.OVER_SCROLL_NEVER);
        WebSettings s = w.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);   // the fallback wallpaper video starts on its own
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);
        return w;
    }

    @SuppressLint({"JavascriptInterface", "AddJavascriptInterface"})
    private WebView newHome() {
        WebView w = newWebView();
        w.setVerticalScrollBarEnabled(false);
        w.setHorizontalScrollBarEnabled(false);
        w.setLongClickable(false);
        w.setOnLongClickListener(v -> true);              // no text selection, no long-press menu
        w.setHapticFeedbackEnabled(false);
        w.addJavascriptInterface(new Bridge(), "dumplingShell");
        w.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onConsoleMessage(ConsoleMessage m) {      // the page's log, into logcat
                Log.i(TAG, "page: " + m.message());
                return true;
            }
        });
        w.setWebViewClient(new WebViewClient() {
            @Override
            public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest req) {
                return assets.shouldInterceptRequest(req.getUrl());
            }

            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest req) {
                // the home page never navigates away: the bridge would go with it
                Uri u = req.getUrl();
                if (sameOrigin(u, Uri.parse(homeUrl))) return false;
                if ("http".equals(u.getScheme()) || "https".equals(u.getScheme())) openWeb(u.toString());
                return true;
            }

            @Override
            public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
                return renderGone(detail);
            }
        });
        return w;
    }

    private WebView newAppView() {
        WebView w = newWebView();
        WebSettings s = w.getSettings();
        s.setUseWideViewPort(true);
        s.setLoadWithOverviewMode(true);
        s.setSupportMultipleWindows(false);
        CookieManager.getInstance().setAcceptThirdPartyCookies(w, true);
        w.setWebChromeClient(new WebChromeClient() {
            @Override   // uploads (Immich, Home Assistant): hand over to Android's file picker
            public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> cb, FileChooserParams params) {
                if (fileCallback != null) fileCallback.onReceiveValue(null);
                fileCallback = cb;
                Intent pick = params.createIntent();
                if (params.getMode() == FileChooserParams.MODE_OPEN_MULTIPLE) pick.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
                try {
                    startActivityForResult(pick, REQ_FILE);
                    return true;
                } catch (ActivityNotFoundException e) {
                    fileCallback = null;
                    return false;
                }
            }
        });
        w.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest req) {
                Uri u = req.getUrl();
                String sc = u.getScheme();
                if ("http".equals(sc) || "https".equals(sc)) return false;    // stays in the web view
                try {                                                         // intent:, tel:, mailto: and the like
                    Intent i = "intent".equals(sc) ? Intent.parseUri(u.toString(), Intent.URI_INTENT_SCHEME)
                            : new Intent(Intent.ACTION_VIEW, u);
                    i.addCategory(Intent.CATEGORY_BROWSABLE).setComponent(null).setSelector(null);
                    startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                } catch (Exception e) {
                    Log.i(TAG, "no app for " + u);
                }
                return true;
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                // a fresh app has no Back history into the previous one
                if (clearAppHistory && !"about:blank".equals(url)) { view.clearHistory(); clearAppHistory = false; }
            }

            @Override
            public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
                return renderGone(detail);
            }
        });
        return w;
    }

    /** The bottom strip under a web app: the bar from the page's design; swipe up on it to come home. */
    @SuppressLint("ClickableViewAccessibility")
    private FrameLayout newEdge() {
        FrameLayout e = new FrameLayout(this);
        e.setBackgroundColor(VOID);
        e.setContentDescription("Swipe up to go home");
        View bar = new View(this);
        GradientDrawable g = new GradientDrawable();
        g.setColor(0x73E9ECF2);
        g.setCornerRadius(dp(3));
        bar.setBackground(g);
        e.addView(bar, new FrameLayout.LayoutParams(dp(120), dp(5), Gravity.CENTER));
        e.setOnTouchListener(new View.OnTouchListener() {
            float y0;
            boolean armed;

            @Override
            public boolean onTouch(View v, MotionEvent ev) {
                switch (ev.getActionMasked()) {
                    case MotionEvent.ACTION_DOWN: y0 = ev.getRawY(); armed = true; break;
                    case MotionEvent.ACTION_MOVE:
                        if (armed && y0 - ev.getRawY() > dp(SWIPE_DP)) { armed = false; goHome(); }
                        break;
                    default: armed = false;
                }
                return true;
            }
        });
        return e;
    }

    /** Both web views share one renderer process; if it dies, rebuild them rather than let Android close us. */
    private boolean renderGone(RenderProcessGoneDetail detail) {
        Log.w(TAG, "web renderer gone (crashed: " + detail.didCrash() + "), rebuilding");
        root.removeView(home);
        root.removeView(appView);
        home.destroy();
        appView.destroy();
        home = newHome();
        appView = newAppView();
        appView.setVisibility(View.GONE);
        root.addView(home, 0, full());
        root.addView(appView, 1, full());
        appShown = false;
        edge.setVisibility(View.GONE);
        layoutApp();
        applyBars();
        home.loadUrl(homeUrl);
        return true;
    }

    // ------------------------------------------------------------------------------------------ the bridge

    /** window.dumplingShell in the page: the same postMessage(json) call as the postmarketOS shell's. */
    private final class Bridge {
        @JavascriptInterface
        public void postMessage(String json) {
            runOnUiThread(() -> handle(json));
        }
    }

    private void handle(String json) {
        try {
            JSONObject m = new JSONObject(json);
            if (m.has("open")) openWeb(m.getString("open"));
            else if (m.has("android")) openAndroid(m.getString("android"), m.optString("name", ""));
            else Log.i(TAG, "ignored from page: " + json);
        } catch (Exception e) {
            Log.w(TAG, "bad message from page: " + json, e);
        }
    }

    private void openWeb(String url) {
        Log.i(TAG, "open " + url);
        clearAppHistory = true;
        appView.loadUrl(url);
        if (!appShown) {
            appShown = true;
            appView.setAlpha(0f);
            appView.setVisibility(View.VISIBLE);
            edge.setVisibility(View.VISIBLE);
            appView.animate().alpha(1f).setDuration(260).withEndAction(() -> {
                // hidden, so the page's wallpaper stops drawing while an app is up
                if (appShown) home.setVisibility(View.INVISIBLE);
            });
        }
        applyBars();
    }

    private void openAndroid(String pkg, String name) {
        String label = name.isEmpty() ? pkg : name;
        Intent i = "settings".equals(pkg) ? new Intent(Settings.ACTION_SETTINGS)
                : getPackageManager().getLaunchIntentForPackage(pkg);
        if (i == null) {
            Log.i(TAG, "not installed: " + pkg);
            Toast.makeText(this, label + " isn't installed (" + pkg + ")", Toast.LENGTH_LONG).show();
            return;
        }
        Log.i(TAG, "start " + pkg);
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
        try {
            startActivity(i);
        } catch (ActivityNotFoundException e) {
            Toast.makeText(this, "Can't open " + label, Toast.LENGTH_LONG).show();
        }
    }

    private void goHome() {
        if (appShown) {
            appShown = false;
            home.setVisibility(View.VISIBLE);
            edge.setVisibility(View.GONE);
            appView.animate().cancel();
            appView.animate().alpha(0f).setDuration(200).withEndAction(() -> {
                if (appShown) return;
                appView.setVisibility(View.GONE);
                appView.loadUrl("about:blank");
            });
        }
        applyBars();
        home.evaluateJavascript("window.launcher && window.launcher.home()", null);
    }

    private void onBack() {
        if (appShown) {
            if (appView.canGoBack()) appView.goBack();
            else goHome();
        } else {
            goHome();          // closes the clock or the ring; the home screen itself never closes
        }
    }

    /** API 30–32; from 33 the OnBackInvokedCallback above takes Back. Never calls super. */
    @Override
    @SuppressWarnings({"deprecation", "MissingSuperCall"})
    @SuppressLint("GestureBackNavigation")
    public void onBackPressed() {
        onBack();
    }

    // ------------------------------------------------------------------------------------------ lifecycle

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        String dev = devUrl(intent);
        if (dev != null && !dev.equals(homeUrl)) {
            homeUrl = dev;
            Log.i(TAG, "home " + homeUrl);
            home.loadUrl(homeUrl);
        }
        goHome();              // Home pressed, or the swipe-up gesture from another app
    }

    @Override
    protected void onResume() {
        super.onResume();
        home.resumeTimers();
        home.onResume();
        appView.onResume();
        applyBars();
    }

    @Override
    protected void onPause() {
        // another app (Telescope streaming, say) has the screen: let the GPU and CPU go
        home.onPause();
        appView.onPause();
        home.pauseTimers();
        super.onPause();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) applyBars();
    }

    @Override
    protected void onActivityResult(int req, int result, Intent data) {
        super.onActivityResult(req, result, data);
        if (req != REQ_FILE || fileCallback == null) return;
        Uri[] picked = null;
        if (result == RESULT_OK && data != null) {
            ClipData clip = data.getClipData();
            if (clip != null) {
                List<Uri> l = new ArrayList<>();
                for (int k = 0; k < clip.getItemCount(); k++) l.add(clip.getItemAt(k).getUri());
                picked = l.toArray(new Uri[0]);
            } else if (data.getData() != null) {
                picked = new Uri[]{data.getData()};
            }
        }
        fileCallback.onReceiveValue(picked);
        fileCallback = null;
    }

    @Override
    protected void onDestroy() {
        root.removeAllViews();
        home.destroy();
        appView.destroy();
        super.onDestroy();
    }

    // ------------------------------------------------------------------------------------------ helpers

    /** The wallpaper fills the screen with the bars hidden; a web app gets the bars back. */
    private void applyBars() {
        WindowInsetsController c = getWindow().getInsetsController();
        if (c == null) return;
        c.setSystemBarsAppearance(0, WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS);
        c.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
        if (appShown) c.show(WindowInsets.Type.systemBars());
        else c.hide(WindowInsets.Type.systemBars());
    }

    /** A web app sits between the status bar and the strip; the strip sits on the nav bar or the keyboard. */
    private void layoutApp() {
        int bottom = Math.max(bars.bottom, ime.bottom);
        FrameLayout.LayoutParams a = (FrameLayout.LayoutParams) appView.getLayoutParams();
        a.topMargin = bars.top;
        a.bottomMargin = bottom + dp(EDGE_DP);
        appView.setLayoutParams(a);
        FrameLayout.LayoutParams e = (FrameLayout.LayoutParams) edge.getLayoutParams();
        e.bottomMargin = bottom;
        edge.setLayoutParams(e);
    }

    private String devUrl(Intent intent) {
        if (!debuggable || intent == null) return null;
        String u = intent.getStringExtra(EXTRA_DEV_URL);
        if (u == null) return null;
        return u.isEmpty() || "bundled".equals(u) ? HOME_URL : u;
    }

    private static boolean sameOrigin(Uri a, Uri b) {
        return a.getScheme() != null && a.getScheme().equals(b.getScheme())
                && a.getHost() != null && a.getHost().equals(b.getHost()) && a.getPort() == b.getPort();
    }

    private static FrameLayout.LayoutParams full() {
        return new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }
}
