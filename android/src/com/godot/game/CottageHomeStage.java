package com.godot.game;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Rect;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ImageView;
import android.widget.TextView;

/**
 * 主页：插画铺满，真实按钮透明地盖在插画已画好的按钮上（与 iPad 启动器 LauncherViewController 的
 * 热区坐标一致）。插画按「铺满」缩放并居中，热区随之换算。
 */
public final class CottageHomeStage extends ViewGroup {
	public static final int HOTSPOT_SAVES = 0;
	public static final int HOTSPOT_MODS = 1;
	public static final int HOTSPOT_NETWORK = 2;
	public static final int HOTSPOT_SETTINGS = 3;
	public static final int HOTSPOT_START = 4;

	// 主页插画 (1536x1024) 里已画好的按钮位置。
	private static final Rect[] HOTSPOT_RECTS = {
		new Rect(52, 405, 52 + 313, 405 + 102),   // 存档管理
		new Rect(52, 522, 52 + 313, 522 + 103),   // 本地 MOD
		new Rect(52, 640, 52 + 313, 640 + 102),   // 联机小屋
		new Rect(52, 757, 52 + 103, 757 + 98),    // 设置
		new Rect(488, 788, 488 + 590, 788 + 147), // 开始游戏
	};

	public interface Listener {
		void onHotspot(int hotspot);

		void onStatusTapped();
	}

	// 插画里需要完整可见的纵向范围（logo 顶部到「开始游戏」底部，留少量边距）。
	private static final int CONTENT_TOP = 40;
	private static final int CONTENT_BOTTOM = 960;

	private final ImageView backdrop;
	private final ImageView art;
	private final View[] hotspots = new View[HOTSPOT_RECTS.length];
	private final TextView statusPill;
	private final Listener listener;
	private float scale;

	public CottageHomeStage(Context context, Listener listener) {
		super(context);
		this.listener = listener;
		setBackgroundColor(CottageTheme.BACKGROUND);
		// 比插画更宽的屏幕（如 20:9 手机横屏）两侧露出的部分用模糊插画填满。
		backdrop = new ImageView(context);
		backdrop.setImageBitmap(CottageTheme.blurredArt(context));
		backdrop.setScaleType(ImageView.ScaleType.CENTER_CROP);
		backdrop.setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
		addView(backdrop);
		art = new ImageView(context);
		art.setImageBitmap(CottageTheme.art(context));
		art.setScaleType(ImageView.ScaleType.FIT_XY);
		art.setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
		addView(art);
		String[] labels = context.getResources().getStringArray(R.array.cottage_hotspot_labels);
		for (int i = 0; i < hotspots.length; i++) {
			View hotspot = new View(context);
			final int index = i;
			hotspot.setContentDescription(labels[i]);
			hotspot.setClickable(true);
			hotspot.setFocusable(true);
			hotspot.setOnClickListener(v -> listener.onHotspot(index));
			hotspots[i] = hotspot;
			addView(hotspot);
		}
		statusPill = CottageTheme.text(context, "", 14, CottageTheme.INK, true);
		statusPill.setGravity(Gravity.CENTER);
		statusPill.setMaxLines(3);
		statusPill.setEllipsize(TextUtils.TruncateAt.END);
		statusPill.setPadding(dp(18), dp(10), dp(18), dp(10));
		GradientDrawable pill = new GradientDrawable();
		pill.setColor(0xEB1B2540);
		pill.setCornerRadius(dp(18));
		pill.setStroke(dp(1.5f), 0xB3FFC76B);
		statusPill.setBackground(pill);
		statusPill.setOnClickListener(v -> listener.onStatusTapped());
		statusPill.setVisibility(GONE);
		addView(statusPill);
	}

	/** 开始按钮上方的状态提示；为 null 时隐藏。 */
	public void setStatus(String text, boolean actionable) {
		statusPill.setText(text == null ? "" : actionable ? text + "  ›" : text);
		statusPill.setClickable(actionable);
		statusPill.setVisibility(text == null ? GONE : VISIBLE);
		requestLayout();
	}

	@Override
	protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
		int width = MeasureSpec.getSize(widthMeasureSpec);
		int height = MeasureSpec.getSize(heightMeasureSpec);
		setMeasuredDimension(width, height);
		// 优先铺满；若铺满会把插画里的按钮裁出屏幕，就按高度让按钮区完整可见。
		float fill = Math.max(width / (float)CottageTheme.ART_WIDTH, height / (float)CottageTheme.ART_HEIGHT);
		float fitContent = height / (float)(CONTENT_BOTTOM - CONTENT_TOP);
		scale = Math.min(fill, fitContent);
		backdrop.measure(MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(height, MeasureSpec.EXACTLY));
		art.measure(MeasureSpec.makeMeasureSpec(Math.round(CottageTheme.ART_WIDTH * scale), MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(Math.round(CottageTheme.ART_HEIGHT * scale), MeasureSpec.EXACTLY));
		for (int i = 0; i < hotspots.length; i++) {
			Rect r = HOTSPOT_RECTS[i];
			hotspots[i].measure(MeasureSpec.makeMeasureSpec(Math.round(r.width() * scale), MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(Math.round(r.height() * scale), MeasureSpec.EXACTLY));
		}
		int maxPillWidth = Math.round(640 * scale);
		statusPill.measure(MeasureSpec.makeMeasureSpec(maxPillWidth, MeasureSpec.AT_MOST), MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED));
	}

	@Override
	protected void onLayout(boolean changed, int l, int t, int r, int b) {
		int width = r - l;
		int height = b - t;
		int originX = Math.round((width - CottageTheme.ART_WIDTH * scale) / 2f);
		int originY = Math.round((height - CottageTheme.ART_HEIGHT * scale) / 2f);
		float artHeight = CottageTheme.ART_HEIGHT * scale;
		if (artHeight > height) {
			// 纵向有裁切时以按钮区为中心，并保证插画仍盖满上下边。
			float centered = height / 2f - (CONTENT_TOP + CONTENT_BOTTOM) / 2f * scale;
			originY = Math.round(Math.max(height - artHeight, Math.min(0, centered)));
		}
		backdrop.layout(0, 0, width, height);
		art.layout(originX, originY, originX + art.getMeasuredWidth(), originY + art.getMeasuredHeight());
		for (int i = 0; i < hotspots.length; i++) {
			Rect rect = HOTSPOT_RECTS[i];
			int left = originX + Math.round(rect.left * scale);
			int top = originY + Math.round(rect.top * scale);
			View hotspot = hotspots[i];
			hotspot.layout(left, top, left + hotspot.getMeasuredWidth(), top + hotspot.getMeasuredHeight());
			// 圆角与插画里的按钮一致：开始游戏是胶囊，左侧菜单是大圆角方块。
			float radius = i == HOTSPOT_START ? hotspot.getMeasuredHeight() / 2f : 26 * scale * 2;
			GradientDrawable mask = new GradientDrawable();
			mask.setColor(Color.WHITE);
			mask.setCornerRadius(radius);
			hotspot.setBackground(new RippleDrawable(ColorStateList.valueOf(0x33FFFFFF), null, mask));
		}
		View start = hotspots[HOTSPOT_START];
		int pillLeft = (start.getLeft() + start.getRight()) / 2 - statusPill.getMeasuredWidth() / 2;
		int pillTop = start.getTop() - statusPill.getMeasuredHeight() - Math.round(10 * scale);
		statusPill.layout(pillLeft, pillTop, pillLeft + statusPill.getMeasuredWidth(), pillTop + statusPill.getMeasuredHeight());
	}

	private int dp(float value) {
		return ExtraSettingsUi.dp(getContext(), value);
	}
}
