package com.godot.game;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import com.godot.game.online.OnlineRoomManager;
import com.godot.game.online.OnlineRoomPreferences;
import com.godot.game.online.OnlineRoomProtocol;
import com.godot.game.online.OnlineRoomScanner;
import com.godot.game.online.OnlineRoomService;
import com.google.android.material.button.MaterialButton;
import com.google.android.material.card.MaterialCardView;
import com.google.android.material.dialog.MaterialAlertDialogBuilder;

import org.json.JSONObject;

import java.io.File;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Date;
import java.util.Enumeration;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * 联机小屋（与 iPad 启动器 renderNetworkPage 对应）：创建在线房间、浏览并加入在线房间、局域网直连与联机设置。
 * 游戏内的开房/加入沿用兼容包已有的 ENet 入口；加入时把地址写进 settings.save 的 lan_join_host / lan_join_port，
 * 游戏的「加入好友」页面会直接带出。
 */
public final class NetworkPage implements OnlineRoomManager.Listener {
	private static final ExecutorService SCAN = Executors.newSingleThreadExecutor(runnable -> {
		Thread thread = new Thread(runnable, "sts2-room-page-scan");
		thread.setDaemon(true);
		return thread;
	});
	// 切换页面再回来时先显示上次的结果，避免每次都从空列表开始。
	private static List<OnlineRoomProtocol.Room> lastRooms = Collections.emptyList();
	private static int scanGeneration;

	private final Context context;
	private final ExtraSettingsRepository repository;
	private final ExtraSettingsActions actions;
	private final OnlineRoomManager manager;
	private final Handler main = new Handler(Looper.getMainLooper());
	private ScrollView scrollView;
	private LinearLayout hostContent;
	private LinearLayout roomsContainer;
	private MaterialButton refreshButton;
	private boolean scanning;

	public NetworkPage(Context context, ExtraSettingsRepository repository, ExtraSettingsActions actions) {
		this.context = context;
		this.repository = repository;
		this.actions = actions;
		this.manager = OnlineRoomPreferences.manager(context);
	}

	public View build() {
		scrollView = new ScrollView(context);
		scrollView.setBackgroundColor(ExtraSettingsUi.COLOR_PAGE_BACKGROUND);
		LinearLayout root = ExtraSettingsUi.vertical(context);
		root.setPadding(0, dp(24), 0, dp(32));
		SystemBarInsetsHelper.applySystemBarPadding(root, true, false, false, false);
		ExtraSettingsUi.addResponsiveScrollContent(context, scrollView, root);

		root.addView(CottageTheme.pageTitle(context, context.getString(R.string.cottage_nav_network), context.getString(R.string.cottage_tagline_network)));

		MaterialCardView hostCard = ExtraSettingsUi.card(context);
		hostContent = ExtraSettingsUi.cardContent(context, hostCard);
		ExtraSettingsUi.addCardSpacing(root, hostCard);

		LinearLayout header = ExtraSettingsUi.horizontal(context);
		header.setGravity(Gravity.CENTER_VERTICAL);
		header.addView(CottageTheme.sectionHeading(context, context.getString(R.string.online_room_list)), new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
		refreshButton = ExtraSettingsUi.textButton(context, context.getString(R.string.online_room_refresh), R.drawable.ic_sync_24);
		refreshButton.setOnClickListener(v -> refreshRooms());
		header.addView(refreshButton);
		LinearLayout.LayoutParams headerParams = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
		headerParams.topMargin = dp(22);
		root.addView(header, headerParams);
		roomsContainer = ExtraSettingsUi.vertical(context);
		LinearLayout.LayoutParams roomsParams = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
		roomsParams.topMargin = dp(8);
		root.addView(roomsContainer, roomsParams);

		addSection(root, R.string.online_room_lan);
		ExtraSettingsUi.addCardSpacing(root, lanCard());
		addSection(root, R.string.online_room_settings);
		ExtraSettingsUi.addCardSpacing(root, settingsCard());
		TextView note = ExtraSettingsUi.caption(context, context.getString(R.string.online_room_note));
		ExtraSettingsUi.addCardSpacing(root, note);

		scrollView.addOnAttachStateChangeListener(new View.OnAttachStateChangeListener() {
			@Override
			public void onViewAttachedToWindow(View view) {
				manager.addListener(NetworkPage.this);
			}

			@Override
			public void onViewDetachedFromWindow(View view) {
				manager.removeListener(NetworkPage.this);
			}
		});
		renderHost(manager.snapshot());
		renderRooms();
		refreshRooms();
		return scrollView;
	}

	@Override
	public void onRoomStateChanged(OnlineRoomManager.Snapshot snapshot) {
		main.post(() -> {
			if (!scrollView.isAttachedToWindow()) {
				return;
			}
			renderHost(snapshot);
			if (snapshot.phase == OnlineRoomManager.Phase.OPEN) {
				refreshRooms();
				showHostDialog();
			} else {
				renderRooms();
			}
		});
	}

	// ---------- 创建房间 ----------

	private void renderHost(OnlineRoomManager.Snapshot snapshot) {
		hostContent.removeAllViews();
		OnlineRoomManager.ServerConfig server = OnlineRoomPreferences.server(context);
		if (!server.isConfigured()) {
			hostContent.addView(ExtraSettingsUi.body(context, context.getString(R.string.online_room_server_missing)));
			return;
		}
		switch (snapshot.phase) {
			case OPEN: {
				OnlineRoomProtocol.Room room = snapshot.room;
				TextView title = CottageTheme.text(context, context.getString(R.string.online_room_open_title, room.name), 18, CottageTheme.CAT, true);
				hostContent.addView(title);
				ExtraSettingsUi.addSmallSpacing(hostContent, ExtraSettingsUi.body(context, context.getString(R.string.online_room_open_desc, snapshot.server, room.port)));
				MaterialButton enter = CottageTheme.primaryButton(context, context.getString(R.string.online_room_enter_host));
				enter.setOnClickListener(v -> showHostDialog());
				addButton(enter, 14);
				MaterialButton close = CottageTheme.secondaryButton(context, context.getString(R.string.online_room_close), "close");
				close.setOnClickListener(v -> manager.closeRoom());
				addButton(close, 10);
				return;
			}
			case STARTING: {
				hostContent.addView(ExtraSettingsUi.body(context, context.getString(R.string.online_room_starting)));
				MaterialButton busy = CottageTheme.primaryButton(context, context.getString(R.string.online_room_starting));
				busy.setEnabled(false);
				addButton(busy, 14);
				return;
			}
			default:
				break;
		}
		if (!manager.isTunnelBinaryAvailable()) {
			hostContent.addView(ExtraSettingsUi.body(context, context.getString(R.string.online_room_frp_missing)));
			return;
		}
		if (snapshot.phase == OnlineRoomManager.Phase.FAILED && !"cancelled".equals(snapshot.error)) {
			TextView error = CottageTheme.text(context, context.getString(R.string.online_room_failed, describeError(snapshot.error)), 14, ExtraSettingsUi.COLOR_ERROR, false);
			hostContent.addView(error);
		}
		MaterialButton create = CottageTheme.primaryButton(context, context.getString(R.string.online_room_create));
		create.setOnClickListener(v -> createRoom());
		addButton(create, hostContent.getChildCount() == 0 ? 0 : 12);
		ExtraSettingsUi.addSmallSpacing(hostContent, ExtraSettingsUi.caption(context, context.getString(hasMultiplayerSave() ? R.string.online_room_create_continuing : R.string.online_room_create_desc)));
	}

	private void createRoom() {
		String version = "";
		try {
			version = new PayloadManager(context).getStatus().version;
		} catch (Exception ignored) {
		}
		manager.createRoom(OnlineRoomPreferences.server(context), OnlineRoomPreferences.nickname(context), version, hasMultiplayerSave());
		OnlineRoomService.start(context);
	}

	private void showHostDialog() {
		new MaterialAlertDialogBuilder(context)
			.setTitle(R.string.online_room_host_dialog_title)
			.setMessage(R.string.online_room_host_dialog)
			.setPositiveButton(R.string.online_room_start_game, (dialog, which) -> actions.launchGame())
			.setNegativeButton(android.R.string.cancel, null)
			.show();
	}

	private String describeError(String error) {
		if ("server_missing".equals(error)) {
			return context.getString(R.string.online_room_server_missing);
		}
		if ("rooms_full".equals(error)) {
			return context.getString(R.string.online_room_rooms_full);
		}
		if ("frp_binary_missing".equals(error)) {
			return context.getString(R.string.online_room_frp_missing);
		}
		return error == null ? "" : error;
	}

	/** 当前启动配置的账号下是否有未完成的多人存档（同 iPad hasMultiplayerSave）。 */
	private boolean hasMultiplayerSave() {
		File account;
		try {
			account = new LaunchProfileManager(context).getSelectedAccountRootDir();
		} catch (Exception exception) {
			return false;
		}
		File[] profiles = account == null ? null : account.listFiles(file -> file.isDirectory() && file.getName().startsWith("profile"));
		if (profiles == null) {
			return false;
		}
		for (File profile : profiles) {
			File save = new File(new File(profile, "saves"), "current_run_mp.save");
			if (save.isFile() || new File(save.getPath() + ".backup").isFile()) {
				return true;
			}
		}
		return false;
	}

	// ---------- 在线房间 ----------

	private void refreshRooms() {
		OnlineRoomManager.ServerConfig server = OnlineRoomPreferences.server(context);
		if (!server.isConfigured() || scanning) {
			renderRooms();
			return;
		}
		scanning = true;
		final int generation = ++scanGeneration;
		renderRooms();
		SCAN.execute(() -> {
			List<OnlineRoomProtocol.Room> rooms = OnlineRoomScanner.scan(server.host, OnlineRoomProtocol.SCAN_TIMEOUT_MS);
			main.post(() -> {
				scanning = false;
				if (generation != scanGeneration) {
					return;
				}
				lastRooms = rooms;
				if (scrollView.isAttachedToWindow() || scrollView.getParent() != null) {
					renderRooms();
				}
			});
		});
	}

	private void renderRooms() {
		roomsContainer.removeAllViews();
		refreshButton.setEnabled(!scanning);
		OnlineRoomManager.ServerConfig server = OnlineRoomPreferences.server(context);
		if (!server.isConfigured()) {
			roomsContainer.addView(ExtraSettingsUi.caption(context, context.getString(R.string.online_room_server_missing)));
			return;
		}
		if (lastRooms.isEmpty()) {
			roomsContainer.addView(ExtraSettingsUi.body(context, context.getString(scanning ? R.string.online_room_scanning : R.string.online_room_empty)));
			return;
		}
		String myVersion = "";
		try {
			myVersion = new PayloadManager(context).getStatus().version;
		} catch (Exception ignored) {
		}
		OnlineRoomManager.Snapshot snapshot = manager.snapshot();
		int mySlot = snapshot.phase == OnlineRoomManager.Phase.OPEN && snapshot.room != null ? snapshot.room.slot : -1;
		SimpleDateFormat time = new SimpleDateFormat("HH:mm", Locale.getDefault());
		for (OnlineRoomProtocol.Room room : lastRooms) {
			MaterialCardView card = ExtraSettingsUi.card(context);
			LinearLayout content = ExtraSettingsUi.cardContent(context, card);
			content.addView(CottageTheme.text(context, room.name, 17, CottageTheme.INK, true));
			List<String> details = new ArrayList<>();
			details.add(context.getString(R.string.online_room_details_version, room.version));
			if (room.createdEpochSeconds > 0) {
				details.add(context.getString(R.string.online_room_details_created, time.format(new Date(room.createdEpochSeconds * 1000L))));
			}
			if (room.continuing) {
				details.add(context.getString(R.string.online_room_details_continuing));
			}
			ExtraSettingsUi.addSmallSpacing(content, ExtraSettingsUi.caption(context, TextUtils.join(" · ", details)));
			if (room.slot == mySlot) {
				ExtraSettingsUi.addSmallSpacing(content, CottageTheme.text(context, context.getString(R.string.online_room_mine), 14, CottageTheme.FISH, true));
			} else {
				boolean sameVersion = room.version.equals(myVersion);
				MaterialButton join = CottageTheme.primaryButton(context, context.getString(sameVersion ? R.string.online_room_join : R.string.online_room_version_mismatch));
				join.setEnabled(sameVersion);
				join.setOnClickListener(v -> joinAndLaunch(server.host, room.port));
				LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
				params.topMargin = dp(12);
				content.addView(join, params);
			}
			ExtraSettingsUi.addCardSpacing(roomsContainer, card);
		}
	}

	// ---------- 局域网直连 ----------

	private View lanCard() {
		MaterialCardView card = ExtraSettingsUi.card(context);
		LinearLayout content = ExtraSettingsUi.cardContent(context, card);
		content.addView(ExtraSettingsUi.body(context, context.getString(R.string.online_room_lan_desc)));
		List<String> addresses = localAddresses();
		String address = addresses.isEmpty()
			? context.getString(R.string.online_room_lan_address_none)
			: context.getString(R.string.online_room_lan_address, TextUtils.join(" / ", addresses), OnlineRoomProtocol.GAME_PORT);
		TextView addressView = CottageTheme.text(context, address, 15, CottageTheme.CAT, true);
		addressView.setTextIsSelectable(true);
		ExtraSettingsUi.addSmallSpacing(content, addressView);

		String savedHost = "";
		int savedPort = OnlineRoomProtocol.GAME_PORT;
		try {
			JSONObject settings = repository.loadSettingsJson();
			savedHost = settings.optString("lan_join_host", "");
			savedPort = settings.optInt("lan_join_port", OnlineRoomProtocol.GAME_PORT);
		} catch (Exception ignored) {
		}
		EditText host = input(R.string.online_room_lan_host_hint, savedHost, InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
		EditText port = input(R.string.online_room_lan_port_hint, String.valueOf(savedPort), InputType.TYPE_CLASS_NUMBER);
		ExtraSettingsUi.addSmallSpacing(content, host);
		ExtraSettingsUi.addSmallSpacing(content, port);
		MaterialButton join = CottageTheme.secondaryButton(context, context.getString(R.string.online_room_lan_join), "play_arrow");
		join.setOnClickListener(v -> {
			String hostText = host.getText().toString().trim();
			int portValue = parsePort(port.getText().toString());
			if (hostText.isEmpty() || hostText.contains(" ") || portValue <= 0) {
				Toast.makeText(context, R.string.online_room_invalid_address, Toast.LENGTH_SHORT).show();
				return;
			}
			joinAndLaunch(hostText, portValue);
		});
		LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
		params.topMargin = dp(12);
		content.addView(join, params);
		return card;
	}

	/** 把地址写进 settings.save，游戏的「加入好友」页面会带出；确认后启动游戏。 */
	private void joinAndLaunch(String host, int port) {
		try {
			repository.saveSetting(root -> {
				root.put("lan_join_host", host);
				root.put("lan_join_port", port);
			});
		} catch (Exception exception) {
			actions.showError(exception);
			return;
		}
		new MaterialAlertDialogBuilder(context)
			.setTitle(R.string.online_room_join_dialog_title)
			.setMessage(context.getString(R.string.online_room_join_dialog, host, port))
			.setPositiveButton(R.string.online_room_start_game, (dialog, which) -> actions.launchGame())
			.setNegativeButton(android.R.string.cancel, null)
			.show();
	}

	private static List<String> localAddresses() {
		List<String> addresses = new ArrayList<>();
		try {
			Enumeration<NetworkInterface> interfaces = NetworkInterface.getNetworkInterfaces();
			while (interfaces != null && interfaces.hasMoreElements()) {
				NetworkInterface network = interfaces.nextElement();
				if (!network.isUp() || network.isLoopback()) {
					continue;
				}
				Enumeration<InetAddress> inet = network.getInetAddresses();
				while (inet.hasMoreElements()) {
					InetAddress address = inet.nextElement();
					if (address instanceof Inet4Address && address.isSiteLocalAddress()) {
						addresses.add(address.getHostAddress());
					}
				}
			}
		} catch (Exception ignored) {
		}
		return addresses;
	}

	// ---------- 联机设置 ----------

	private View settingsCard() {
		MaterialCardView card = ExtraSettingsUi.card(context);
		LinearLayout content = ExtraSettingsUi.cardContent(context, card);
		OnlineRoomManager.ServerConfig server = OnlineRoomPreferences.server(context);
		EditText nickname = input(R.string.online_room_nickname_hint, OnlineRoomPreferences.nickname(context), InputType.TYPE_CLASS_TEXT);
		EditText host = input(R.string.online_room_server_hint, server.host, InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
		EditText port = input(R.string.online_room_server_port_hint, String.valueOf(server.port), InputType.TYPE_CLASS_NUMBER);
		EditText token = input(R.string.online_room_token_hint, server.token, InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
		for (EditText field : new EditText[] { nickname, host, port, token }) {
			ExtraSettingsUi.addSmallSpacing(content, field);
		}
		MaterialButton save = CottageTheme.secondaryButton(context, context.getString(R.string.online_room_save), "save");
		save.setOnClickListener(v -> {
			OnlineRoomPreferences.setNickname(context, nickname.getText().toString());
			int portValue = parsePort(port.getText().toString());
			OnlineRoomPreferences.setServer(context, host.getText().toString(), portValue > 0 ? portValue : OnlineRoomProtocol.DEFAULT_SERVER_PORT, token.getText().toString());
			Toast.makeText(context, R.string.online_room_saved, Toast.LENGTH_SHORT).show();
			renderHost(manager.snapshot());
			refreshRooms();
		});
		LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
		params.topMargin = dp(12);
		content.addView(save, params);
		return card;
	}

	// ---------- 小工具 ----------

	private EditText input(int hintRes, String value, int inputType) {
		EditText field = new EditText(context);
		field.setHint(hintRes);
		field.setSingleLine(true);
		field.setInputType(inputType);
		field.setText(value == null ? "" : value);
		field.setTextColor(ExtraSettingsUi.COLOR_ON_SURFACE);
		field.setHintTextColor(ExtraSettingsUi.COLOR_MUTED);
		return field;
	}

	private static int parsePort(String text) {
		try {
			int port = Integer.parseInt(text.trim());
			return port > 0 && port <= 65535 ? port : -1;
		} catch (NumberFormatException exception) {
			return -1;
		}
	}

	private void addSection(LinearLayout root, int titleRes) {
		LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
		params.topMargin = dp(22);
		root.addView(CottageTheme.sectionHeading(context, context.getString(titleRes)), params);
	}

	private void addButton(MaterialButton button, int topMarginDp) {
		LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
		params.topMargin = dp(topMarginDp);
		hostContent.addView(button, params);
	}

	private int dp(float value) {
		return ExtraSettingsUi.dp(context, value);
	}
}
