package com.godot.game;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.ColorFilter;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.text.TextPaint;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import androidx.appcompat.widget.AppCompatTextView;

import com.google.android.material.button.MaterialButton;
import com.google.android.material.imageview.ShapeableImageView;
import com.google.android.material.shape.ShapeAppearanceModel;

/**
 * 主题：喵喵零和小鱼的小屋。与 iPad 启动器（sts2-ios launcher/STS2Theme）共用同一张插画、
 * 夜间小屋配色、描边标题和吉祥物，需要改配色或形象只改这一个文件。
 */
public final class CottageTheme {
	// 夜晚小屋：深蓝夜色 + 奶油字 + 灯笼琥珀 + 海蓝，取自启动器插画的配色。
	public static final int BACKGROUND = 0xFF121A33;
	public static final int CARD = 0xE01B2540;
	public static final int CARD_SOLID = 0xFF1B2540;
	public static final int CARD_HIGH = 0xFF24304F;
	public static final int OUTLINE = 0xFF3A476B;
	public static final int INK = 0xFFFFF1D6;
	public static final int INK_SOFT = 0xFFB9C2DA;
	public static final int MUTED = 0xFF8B94AF;
	public static final int CAT = 0xFFFFC76B;
	public static final int FISH = 0xFF7FB7FF;
	public static final int CREAM = 0xFFFFF2D8;
	public static final int NAVY = 0xFF1B2540;
	public static final int SECONDARY = 0xFF2C3A63;
	public static final int RIPPLE = 0x48FFC76B;
	/** 选中卡片：夜色上叠一层淡淡的灯笼琥珀。 */
	public static final int SELECTED_CARD = 0xEB3D3D46;
	public static final int SELECTED_BORDER = 0xFF8A7448;
	/** 子页面插画背景上的压暗层（同 iPad：rgb(0.05,0.08,0.18) @ 45%）。 */
	public static final int DIM = 0x730D142E;

	/** 主页插画 (1536x1024) 与其中已画好的区域，坐标与 iPad 启动器一致。 */
	public static final int ART_WIDTH = 1536;
	public static final int ART_HEIGHT = 1024;
	public static final Rect BRAND_RECT = new Rect(36, 64, 36 + 576, 64 + 308);
	public static final Rect POSTCARD_RECT = new Rect(560, 372, 560 + 715, 372 + 380);

	private static Bitmap art;
	private static Bitmap blurredArt;

	private CottageTheme() {
	}

	public static Bitmap art(Context context) {
		if (art == null) {
			BitmapFactory.Options options = new BitmapFactory.Options();
			options.inScaled = false;
			art = BitmapFactory.decodeResource(context.getResources(), R.drawable.launcher_home, options);
		}
		return art;
	}

	/** 从启动器插画里按像素矩形裁出一块（logo、猫和鲨鱼等）。 */
	public static Bitmap artCrop(Context context, Rect pixelRect) {
		Bitmap source = art(context);
		return source == null ? null : Bitmap.createBitmap(source, pixelRect.left, pixelRect.top, pixelRect.width(), pixelRect.height());
	}

	/** 子页面背景：同一张插画，只做轻度模糊（保留灯笼和窗外夜景的轮廓）。 */
	public static Bitmap blurredArt(Context context) {
		if (blurredArt == null) {
			Bitmap source = art(context);
			if (source == null) {
				return null;
			}
			Bitmap small = Bitmap.createScaledBitmap(source, 192, 128, true).copy(Bitmap.Config.ARGB_8888, true);
			int w = small.getWidth();
			int h = small.getHeight();
			int[] pixels = new int[w * h];
			small.getPixels(pixels, 0, w, 0, 0, w, h);
			for (int pass = 0; pass < 3; pass++) {
				boxBlur(pixels, w, h, 3, true);
				boxBlur(pixels, w, h, 3, false);
			}
			small.setPixels(pixels, 0, w, 0, 0, w, h);
			blurredArt = small;
		}
		return blurredArt;
	}

	private static void boxBlur(int[] pixels, int w, int h, int radius, boolean horizontal) {
		int lines = horizontal ? h : w;
		int length = horizontal ? w : h;
		int[] line = new int[length];
		for (int l = 0; l < lines; l++) {
			for (int i = 0; i < length; i++) {
				line[i] = pixels[horizontal ? l * w + i : i * w + l];
			}
			for (int i = 0; i < length; i++) {
				int r = 0, g = 0, b = 0, n = 0;
				for (int k = Math.max(0, i - radius); k <= Math.min(length - 1, i + radius); k++) {
					int c = line[k];
					r += (c >> 16) & 255;
					g += (c >> 8) & 255;
					b += c & 255;
					n++;
				}
				pixels[horizontal ? l * w + i : i * w + l] = 0xFF000000 | ((r / n) << 16) | ((g / n) << 8) | (b / n);
			}
		}
	}

	/** 插画裁片：圆角 + 描边，像贴在小屋墙上的画。 */
	public static ImageView artCard(Context context, Rect pixelRect, String description) {
		ShapeableImageView image = new ShapeableImageView(context);
		image.setImageBitmap(artCrop(context, pixelRect));
		image.setAdjustViewBounds(true);
		image.setScaleType(ImageView.ScaleType.CENTER_CROP);
		image.setShapeAppearanceModel(ShapeAppearanceModel.builder().setAllCornerSizes(dp(context, 20)).build());
		image.setStrokeColor(ColorStateList.valueOf(OUTLINE));
		int stroke = dp(context, 2);
		image.setStrokeWidth(stroke);
		image.setPadding(stroke / 2, stroke / 2, stroke / 2, stroke / 2);
		image.setContentDescription(description);
		return image;
	}

	/** 与插画 logo 同款的粗体描边标题（暖奶油填充 + 深蓝描边 + 向下的硬阴影）。 */
	public static TextView outlinedTitle(Context context, String text, float sp) {
		return new OutlinedTitleView(context, text, sp);
	}

	/** 页面标题：描边标题，下面一条「— 标语 —」小标签。 */
	public static View pageTitle(Context context, String title, String tagline) {
		LinearLayout stack = ExtraSettingsUi.vertical(context);
		stack.setGravity(Gravity.START);
		TextView heading = outlinedTitle(context, title, 30);
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
			heading.setAccessibilityHeading(true);
		}
		stack.addView(heading, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));
		if (!TextUtils.isEmpty(tagline)) {
			TextView pill = text(context, "—  " + tagline + "  —", 12, CAT, true);
			pill.setPadding(dp(context, 14), dp(context, 5), dp(context, 14), dp(context, 5));
			GradientDrawable background = new GradientDrawable();
			background.setColor(0xE61B2540);
			background.setCornerRadius(dp(context, 15));
			background.setStroke(dp(context, 1.5f), 0xB3FFC76B);
			pill.setBackground(background);
			LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
			params.topMargin = dp(context, 6);
			stack.addView(pill, params);
		}
		return stack;
	}

	public static TextView sectionHeading(Context context, String value) {
		return text(context, "✦ " + value, 17, CAT, true);
	}

	public static TextView text(Context context, String value, float sp, int color, boolean bold) {
		TextView view = new TextView(context);
		view.setText(value);
		view.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
		view.setTextColor(color);
		view.setTypeface(Typeface.DEFAULT, bold ? Typeface.BOLD : Typeface.NORMAL);
		return view;
	}

	/** 奶油色大按钮，同插画里的「开始游戏」：标题后跟一枚琥珀色小猫爪。 */
	public static MaterialButton primaryButton(Context context, String title) {
		MaterialButton button = baseButton(context, title, CREAM, NAVY, true);
		button.setIcon(new PawDrawable(CAT));
		button.setIconTint(null);
		button.setIconSize(dp(context, 20));
		button.setIconGravity(MaterialButton.ICON_GRAVITY_TEXT_END);
		button.setIconPadding(dp(context, 10));
		return button;
	}

	/** 小鲨鱼海蓝次要按钮。 */
	public static MaterialButton secondaryButton(Context context, String title, String glyph) {
		MaterialButton button = baseButton(context, title, SECONDARY, INK, true);
		if (glyph != null) {
			MaterialSymbols.applyButtonIcon(button, glyph, ColorStateList.valueOf(INK), 20);
			button.setIconGravity(MaterialButton.ICON_GRAVITY_TEXT_START);
			button.setIconPadding(dp(context, 10));
		}
		return button;
	}

	/** 侧栏按钮：深色圆角方块，选中时为灯笼琥珀色，同插画左侧菜单。 */
	public static MaterialButton navButton(Context context, String title, String glyph, boolean selected) {
		MaterialButton button = baseButton(context, title, 0, 0, false);
		button.setGravity(Gravity.START | Gravity.CENTER_VERTICAL);
		button.setIconGravity(MaterialButton.ICON_GRAVITY_START);
		button.setIconPadding(dp(context, 12));
		button.setTag(glyph);
		applyNavSelected(button, selected);
		return button;
	}

	public static void applyNavSelected(MaterialButton button, boolean selected) {
		int background = selected ? CAT : 0xE61B2540;
		int foreground = selected ? NAVY : INK;
		button.setBackgroundTintList(ColorStateList.valueOf(background));
		button.setTextColor(foreground);
		button.setStrokeColor(ColorStateList.valueOf(selected ? CAT : OUTLINE));
		button.setStrokeWidth(dp(button.getContext(), 1.5f));
		Object glyph = button.getTag();
		if (glyph instanceof String) {
			MaterialSymbols.applyButtonIcon(button, (String)glyph, ColorStateList.valueOf(foreground), 22);
		}
	}

	private static MaterialButton baseButton(Context context, String title, int background, int foreground, boolean capsule) {
		MaterialButton button = new MaterialButton(context);
		button.setText(title);
		button.setAllCaps(false);
		button.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
		button.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
		button.setSingleLine(true);
		button.setEllipsize(TextUtils.TruncateAt.MIDDLE);
		button.setInsetTop(0);
		button.setInsetBottom(0);
		button.setMinHeight(dp(context, 52));
		button.setMinimumHeight(dp(context, 52));
		button.setPadding(dp(context, 18), dp(context, 12), dp(context, 18), dp(context, 12));
		button.setTextColor(foreground);
		button.setBackgroundTintList(ColorStateList.valueOf(background));
		button.setRippleColor(ColorStateList.valueOf(capsule && background == CREAM ? 0x401B2540 : RIPPLE));
		button.setShapeAppearanceModel(ShapeAppearanceModel.builder().setAllCornerSizes(capsule ? dp(context, 26) : dp(context, 16)).build());
		return button;
	}

	/** 圆角奶油卡片底色（夜间小屋版）。 */
	public static GradientDrawable cardBackground(Context context) {
		GradientDrawable drawable = new GradientDrawable();
		drawable.setColor(CARD);
		drawable.setCornerRadius(dp(context, 26));
		drawable.setStroke(dp(context, 1.5f), OUTLINE);
		return drawable;
	}

	/** 喵喵零（小猫）和小鱼（小鲨鱼）并排。 */
	public static LinearLayout mascotRow(Context context, int sizeDp) {
		LinearLayout row = ExtraSettingsUi.horizontal(context);
		row.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS);
		int size = dp(context, sizeDp);
		row.addView(new MascotView(context, true), new LinearLayout.LayoutParams(size, size));
		LinearLayout.LayoutParams shark = new LinearLayout.LayoutParams(size, size);
		shark.setMarginStart(dp(context, 8));
		row.addView(new MascotView(context, false), shark);
		return row;
	}

	static int dp(Context context, float value) {
		return ExtraSettingsUi.dp(context, value);
	}

	private static Typeface heavyTypeface() {
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
			return Typeface.create(Typeface.DEFAULT, 900, false);
		}
		return Typeface.DEFAULT_BOLD;
	}

	/** 贴纸感：奶油填充 + 深蓝描边 + 向下的硬阴影，在任何背景上都清晰。 */
	private static final class OutlinedTitleView extends AppCompatTextView {
		private static final int FILL = 0xFFFFEBC8;
		private static final int STROKE = 0xFF1B2540;
		private static final int SHADOW = 0xFF0B1022;
		private final float strokeWidth;
		private final float shadowOffset;
		private boolean drawingPasses;

		OutlinedTitleView(Context context, String text, float sp) {
			super(context);
			setText(text);
			setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
			setTypeface(heavyTypeface());
			setTextColor(FILL);
			strokeWidth = getTextSize() * 0.11f;
			shadowOffset = dp(context, 3);
			int pad = (int)Math.ceil(strokeWidth);
			setPadding(pad, pad, pad, pad + (int)shadowOffset);
		}

		@Override
		public void invalidate() {
			if (!drawingPasses) {
				super.invalidate();
			}
		}

		@Override
		protected void onDraw(Canvas canvas) {
			drawingPasses = true;
			TextPaint paint = getPaint();
			paint.setStrokeJoin(Paint.Join.ROUND);
			paint.setStyle(Paint.Style.FILL_AND_STROKE);
			paint.setStrokeWidth(strokeWidth);
			setTextColor(SHADOW);
			canvas.save();
			canvas.translate(0, shadowOffset);
			super.onDraw(canvas);
			canvas.restore();
			setTextColor(STROKE);
			super.onDraw(canvas);
			paint.setStyle(Paint.Style.FILL);
			paint.setStrokeWidth(0);
			setTextColor(FILL);
			super.onDraw(canvas);
			drawingPasses = false;
		}
	}

	/** 小猫爪：一个掌垫 + 四个趾垫。 */
	public static final class PawDrawable extends Drawable {
		private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
		private final RectF oval = new RectF();

		public PawDrawable(int color) {
			paint.setColor(color);
		}

		@Override
		public void draw(Canvas canvas) {
			Rect b = getBounds();
			float s = Math.min(b.width(), b.height()) / 24f;
			canvas.save();
			canvas.translate(b.left + (b.width() - 24 * s) / 2f, b.top + (b.height() - 24 * s) / 2f);
			oval.set(6.5f * s, 11.5f * s, 17.5f * s, 21f * s);
			canvas.drawOval(oval, paint);
			drawToe(canvas, s, 4.5f, 9.5f);
			drawToe(canvas, s, 9f, 5.5f);
			drawToe(canvas, s, 15f, 5.5f);
			drawToe(canvas, s, 19.5f, 9.5f);
			canvas.restore();
		}

		private void drawToe(Canvas canvas, float s, float cx, float cy) {
			oval.set((cx - 2.3f) * s, (cy - 2.8f) * s, (cx + 2.3f) * s, (cy + 2.8f) * s);
			canvas.drawOval(oval, paint);
		}

		@Override
		public int getIntrinsicWidth() {
			return 48;
		}

		@Override
		public int getIntrinsicHeight() {
			return 48;
		}

		@Override
		public void setAlpha(int alpha) {
			paint.setAlpha(alpha);
		}

		@Override
		public void setColorFilter(ColorFilter colorFilter) {
			paint.setColorFilter(colorFilter);
		}

		@Override
		public int getOpacity() {
			return PixelFormat.TRANSLUCENT;
		}
	}

	/** 原创矢量吉祥物（纯代码绘制，不使用任何外部图片或第三方角色素材）。 */
	public static final class MascotView extends View {
		private final boolean cat;
		private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
		// 吉祥物自带浅色填充，描边固定深棕；随深色模式变浅会让眼睛消失在奶白脸上。
		private static final int INK_BROWN = 0xFF5A3A2E;

		public MascotView(Context context, boolean cat) {
			super(context);
			this.cat = cat;
			setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
			paint.setStrokeJoin(Paint.Join.ROUND);
			paint.setStrokeCap(Paint.Cap.ROUND);
		}

		@Override
		protected void onDraw(Canvas canvas) {
			canvas.save();
			canvas.scale(getWidth() / 100f, getHeight() / 100f);
			if (cat) {
				drawCat(canvas);
			} else {
				drawShark(canvas);
			}
			canvas.restore();
		}

		private void paint(Canvas canvas, Path path, int fill, int stroke, float width) {
			if (fill != 0) {
				paint.setStyle(Paint.Style.FILL);
				paint.setColor(fill);
				canvas.drawPath(path, paint);
			}
			if (stroke != 0) {
				paint.setStyle(Paint.Style.STROKE);
				paint.setStrokeWidth(width);
				paint.setColor(stroke);
				canvas.drawPath(path, paint);
			}
		}

		private static Path poly(float... xy) {
			Path path = new Path();
			path.moveTo(xy[0], xy[1]);
			for (int i = 2; i < xy.length; i += 2) {
				path.lineTo(xy[i], xy[i + 1]);
			}
			path.close();
			return path;
		}

		private static Path oval(float x, float y, float w, float h) {
			Path path = new Path();
			path.addOval(new RectF(x, y, x + w, y + h), Path.Direction.CW);
			return path;
		}

		private static Path circle(float x, float y, float r) {
			return oval(x - r, y - r, 2 * r, 2 * r);
		}

		private static Path line(float x1, float y1, float x2, float y2) {
			Path path = new Path();
			path.moveTo(x1, y1);
			path.lineTo(x2, y2);
			return path;
		}

		// 呆猫：奶白脸、放空的小圆眼、八字分脸花纹。
		private void drawCat(Canvas canvas) {
			int fur = 0xFFFFF8EE, patch = 0xFF8C6B5A, pink = 0xFFFFB3B8;
			paint(canvas, poly(14, 44, 16, 8, 44, 28), fur, INK_BROWN, 2.6f);
			paint(canvas, poly(86, 44, 84, 8, 56, 28), fur, INK_BROWN, 2.6f);
			paint(canvas, poly(20, 38, 21, 17, 36, 30), pink, 0, 0);
			paint(canvas, poly(80, 38, 79, 17, 64, 30), pink, 0, 0);
			paint(canvas, oval(8, 26, 84, 66), fur, INK_BROWN, 2.6f);
			// 八字花纹：从额头中线向两侧分开
			paint(canvas, poly(46, 29, 54, 29, 41, 52, 29, 52), patch, 0, 0);
			paint(canvas, poly(54, 29, 46, 29, 59, 52, 71, 52), patch, 0, 0);
			// 呆呆的眼睛和小嘴
			paint(canvas, circle(35, 64, 3.8f), INK_BROWN, 0, 0);
			paint(canvas, circle(65, 64, 3.8f), INK_BROWN, 0, 0);
			paint(canvas, circle(23, 73, 5.5f), 0xB3FFB3B8, 0, 0);
			paint(canvas, circle(77, 73, 5.5f), 0xB3FFB3B8, 0, 0);
			Path mouth = new Path();
			mouth.moveTo(44, 74);
			mouth.quadTo(46, 79, 50, 77);
			mouth.quadTo(54, 79, 56, 74);
			paint(canvas, mouth, 0, INK_BROWN, 2.6f);
			for (int side = -1; side <= 1; side += 2) {
				for (int i = 0; i < 2; i++) {
					paint(canvas, line(50 + side * 34, 70 + i * 5, 50 + side * 47, 66 + i * 10), 0, INK_BROWN, 1.8f);
				}
			}
		}

		// 小鲨鱼：圆圆的蓝灰身体、大眼睛、带小尖牙的笑。
		private void drawShark(Canvas canvas) {
			int body = 0xFF8CC8E3, belly = 0xFFF4FBFF;
			paint(canvas, poly(88, 56, 99, 38, 99, 74), body, INK_BROWN, 2.6f);
			paint(canvas, poly(42, 36, 55, 5, 66, 36), body, INK_BROWN, 2.6f);
			paint(canvas, oval(6, 28, 88, 58), body, INK_BROWN, 2.6f);
			paint(canvas, oval(20, 60, 56, 22), belly, 0, 0);
			for (int i = 0; i < 3; i++) {
				paint(canvas, line(74 + i * 4, 50, 72 + i * 4, 58), 0, INK_BROWN, 1.8f);
			}
			paint(canvas, circle(32, 52, 7), Color.WHITE, INK_BROWN, 2.6f);
			paint(canvas, circle(58, 52, 7), Color.WHITE, INK_BROWN, 2.6f);
			paint(canvas, circle(33, 53, 3.8f), INK_BROWN, 0, 0);
			paint(canvas, circle(59, 53, 3.8f), INK_BROWN, 0, 0);
			paint(canvas, circle(34.5f, 51.2f, 1.3f), Color.WHITE, 0, 0);
			paint(canvas, circle(60.5f, 51.2f, 1.3f), Color.WHITE, 0, 0);
			paint(canvas, circle(21, 65, 4.5f), 0xBFFFB3B8, 0, 0);
			paint(canvas, circle(69, 65, 4.5f), 0xBFFFB3B8, 0, 0);
			Path smile = new Path();
			smile.moveTo(36, 67);
			smile.quadTo(45, 77, 54, 67);
			paint(canvas, smile, 0, INK_BROWN, 2.6f);
			paint(canvas, poly(39, 69, 43, 69, 41, 74), Color.WHITE, 0, 0);
			paint(canvas, poly(47, 69, 51, 69, 49, 74), Color.WHITE, 0, 0);
		}
	}

	/** 全屏插画层：按「铺满」方式缩放，与 iPad 启动器主页的计算一致。 */
	public static FrameLayout.LayoutParams fill() {
		return new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
	}
}
