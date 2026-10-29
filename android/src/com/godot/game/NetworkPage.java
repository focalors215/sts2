package com.godot.game;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;

import com.google.android.material.button.MaterialButton;
import com.google.android.material.card.MaterialCardView;

import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

/** 联机小屋: online rooms on the central frp server, same flow as the iPad launcher. */
public final class NetworkPage {
	private static List<OnlineRoomService.Room> rooms = new ArrayList<>();
	private static boolean scanned;

	private final Context context;
	private final ExtraSettingsActions actions;
	private final OnlineRoomService service;
	private LinearLayout roomList;
	private MaterialButton refreshButton;
	private boolean scanning;

	public NetworkPage(Context context, ExtraSettingsActions actions) {
		this.context = context;
		this.actions = actions;
		this.service = OnlineRoomService.get(context);
	}

	public View build() {
		ScrollView scrollView = new ScrollView(context);
		scrollView.setFillViewport(false);
		scrollView.setBackgroundColor(ExtraSettingsUi.COLOR_PAGE_BACKGROUND);
		LinearLayout root = ExtraSettingsUi.vertical(context);
		root.setPadding(0, ExtraSettingsUi.dp(context, 24), 0, ExtraSettingsUi.dp(context, 32));
		SystemBarInsetsHelper.applySystemBarPadding(root, true, false, false, false);
		ExtraSettingsUi.addResponsiveScrollContent(context, scrollView, root);

		root.addView(CottageTheme.pageTitle(context, context.getString(R.string.cottage_nav_network), context.getString(R.string.cottage_tagline_network)));
		if (!OnlineRoomService.isConfigured()) {
			ExtraSettingsUi.addCardSpacing(root, messageCard(context.getString(FrpBridge.isAvailable() ? R.string.online_not_configured : R.string.online_component_missing)));
			return scrollView;
		}
		ExtraSettingsUi.addCardSpacing(root, profileCard());
		ExtraSettingsUi.addCardSpacing(root, createCard());
		ExtraSettingsUi.addCardSpacing(root, roomsHeader());
		roomList = ExtraSettingsUi.vertical(context);
		root.addView(roomList);
		renderRooms();
		if (!scanned) {
			refreshRooms();
		}
		return scrollView;
	}

	private View profileCard() {
		MaterialCardView card = ExtraSettingsUi.card(context);
		LinearLayout content = ExtraSettingsUi.cardContent(context, card);
		content.addView(ExtraSettingsUi.sectionTitle(context, R.string.online_nickname_title));
		content.addView(ExtraSettingsUi.body(context, R.string.online_nickname_desc));
		LinearLayout row = ExtraSettingsUi.horizontal(context);
		row.setGravity(Gravity.CENTER_VERTICAL);
		EditText input = new EditText(context);
		input.setSingleLine(true);
		input.setInputType(InputType.TYPE_CLASS_TEXT);
		input.setImeOptions(EditorInfo.IME_ACTION_DONE);
		input.setText(service.getNickname());
		input.setTextColor(ExtraSettingsUi.COLOR_ON_SURFACE);
		input.setHintTextColor(ExtraSettingsUi.COLOR_MUTED);
		input.setHint(R.string.online_default_nickname);
		row.addView(input, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
		MaterialButton save = CottageTheme.secondaryButton(context, context.getString(R.string.online_nickname_save), "check");
		LinearLayout.LayoutParams saveParams = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
		saveParams.setMarginStart(ExtraSettingsUi.dp(context, 12));
		row.addView(save, saveParams);
		Runnable persist = () -> {
			service.setNickname(input.getText().toString());
			input.setText(service.getNickname());
			hideKeyboard(input);
		};
		save.setOnClickListener(v -> {
			persist.run();
			actions.showMessage(context.getString(R.string.online_nickname_saved));
		});
		input.setOnEditorActionListener((view, actionId, event) -> {
			if (actionId == EditorInfo.IME_ACTION_DONE) {
				persist.run();
			}
			return false;
		});
		input.setOnFocusChangeListener((view, hasFocus) -> {
			if (!hasFocus) {
				service.setNickname(input.getText().toString());
			}
		});
		ExtraSettingsUi.addSmallSpacing(content, row);
		return card;
	}

	private View createCard() {
		MaterialCardView card = ExtraSettingsUi.card(context);
		LinearLayout content = ExtraSettingsUi.cardContent(context, card);
		content.addView(ExtraSettingsUi.sectionTitle(context, R.string.online_create_title));
		content.addView(ExtraSettingsUi.body(context, service.hasMultiplayerSave() ? context.getString(R.string.online_create_continuing) : context.getString(R.string.online_create_desc)));
		MaterialButton create = CottageTheme.primaryButton(context, context.getString(R.string.online_create_button));
		MaterialSymbols.applyButtonIcon(create, "add_circle", android.content.res.ColorStateList.valueOf(ExtraSettingsUi.COLOR_ON_PRIMARY), 20);
		create.setOnClickListener(v -> createRoom());
		ExtraSettingsUi.addSmallSpacing(content, create);
		return card;
	}

	private View roomsHeader() {
		LinearLayout row = ExtraSettingsUi.horizontal(context);
		row.setGravity(Gravity.CENTER_VERTICAL);
		row.addView(CottageTheme.sectionHeading(context, context.getString(R.string.online_rooms_title)), new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
		refreshButton = CottageTheme.secondaryButton(context, context.getString(R.string.online_refresh), "refresh");
		refreshButton.setOnClickListener(v -> refreshRooms());
		row.addView(refreshButton);
		return row;
	}

	private void renderRooms() {
		if (roomList == null) {
			return;
		}
		roomList.removeAllViews();
		if (refreshButton != null) {
			refreshButton.setEnabled(!scanning);
		}
		if (scanning && rooms.isEmpty()) {
			ExtraSettingsUi.addCardSpacing(roomList, messageCard(context.getString(R.string.online_scanning)));
			return;
		}
		if (rooms.isEmpty()) {
			ExtraSettingsUi.addCardSpacing(roomList, messageCard(context.getString(R.string.online_no_rooms)));
			return;
		}
		String myVersion = service.gameVersion();
		for (OnlineRoomService.Room room : rooms) {
			ExtraSettingsUi.addCardSpacing(roomList, roomCard(room, myVersion));
		}
	}

	private View roomCard(OnlineRoomService.Room room, String myVersion) {
		boolean sameVersion = room.version.equals(myVersion);
		MaterialCardView card = ExtraSettingsUi.card(context);
		LinearLayout content = ExtraSettingsUi.cardContent(context, card);
		LinearLayout row = ExtraSettingsUi.horizontal(context);
		row.setGravity(Gravity.CENTER_VERTICAL);
		row.addView(ExtraSettingsUi.iconCircle(context, R.drawable.ic_groups_24, ExtraSettingsUi.COLOR_PRIMARY_CONTAINER, ExtraSettingsUi.COLOR_ON_PRIMARY_CONTAINER));
		LinearLayout texts = ExtraSettingsUi.vertical(context);
		LinearLayout.LayoutParams textParams = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
		textParams.setMarginStart(ExtraSettingsUi.dp(context, 14));
		row.addView(texts, textParams);
		texts.addView(ExtraSettingsUi.sectionTitle(context, room.name));
		String detail = context.getString(R.string.online_room_version_format, room.version);
		if (room.continuing) {
			detail += context.getString(R.string.online_room_continuing_suffix);
		}
		if (!sameVersion) {
			detail += context.getString(R.string.online_room_version_mismatch_format, myVersion);
		}
		texts.addView(ExtraSettingsUi.caption(context, detail));
		MaterialButton join = sameVersion
			? CottageTheme.primaryButton(context, context.getString(R.string.online_join))
			: CottageTheme.secondaryButton(context, context.getString(R.string.online_version_differs), null);
		join.setEnabled(sameVersion);
		join.setOnClickListener(v -> joinRoom(room));
		LinearLayout.LayoutParams joinParams = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
		joinParams.setMarginStart(ExtraSettingsUi.dp(context, 12));
		row.addView(join, joinParams);
		content.addView(row);
		return card;
	}

	private View messageCard(String message) {
		MaterialCardView card = ExtraSettingsUi.card(context);
		LinearLayout content = ExtraSettingsUi.cardContent(context, card);
		content.addView(ExtraSettingsUi.body(context, message));
		return card;
	}

	private void refreshRooms() {
		if (scanning) {
			return;
		}
		scanning = true;
		renderRooms();
		service.scanRooms((found, error) -> {
			scanning = false;
			scanned = true;
			rooms = found;
			renderRooms();
		});
	}

	private void createRoom() {
		if (!(context instanceof Activity) || ((Activity)context).isFinishing()) {
			return;
		}
		AlertDialog progress = new AlertDialog.Builder(context)
			.setTitle(R.string.online_creating_title)
			.setMessage(R.string.online_creating_message)
			.setCancelable(false)
			.show();
		service.createRoom((room, error) -> {
			if (((Activity)context).isFinishing()) {
				return;
			}
			progress.dismiss();
			if (error != null) {
				new AlertDialog.Builder(context)
					.setTitle(R.string.online_create_failed)
					.setMessage(error)
					.setPositiveButton(android.R.string.ok, null)
					.show();
				return;
			}
			startWithAction(new JSONObject(), "host", null, 0);
		});
	}

	private void joinRoom(OnlineRoomService.Room room) {
		startWithAction(new JSONObject(), "join", OnlineRoomService.server(), room.port);
	}

	private void startWithAction(JSONObject action, String type, String host, int port) {
		try {
			action.put("type", type);
			if (host != null) {
				action.put("host", host);
				action.put("port", port);
			}
			service.writePendingAction(action);
		} catch (Exception exception) {
			actions.showError(exception);
			return;
		}
		actions.launchGame();
	}

	private void hideKeyboard(View view) {
		view.clearFocus();
		InputMethodManager manager = (InputMethodManager)context.getSystemService(Context.INPUT_METHOD_SERVICE);
		if (manager != null) {
			manager.hideSoftInputFromWindow(view.getWindowToken(), 0);
		}
	}
}
