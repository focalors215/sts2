package com.godot.game.online;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;

import com.godot.game.GameSettingsActivity;
import com.godot.game.R;

/**
 * 房间开放期间的前台服务：游戏在前台时启动器进入后台，靠它保住进程里的 frpc 映射和房间卡片。
 * 房间关闭或连接断开时自行停止；通知上可以直接关房。
 */
public final class OnlineRoomService extends Service implements OnlineRoomManager.Listener {
	private static final String CHANNEL_ID = "sts2_online_room";
	private static final int NOTIFICATION_ID = 0x5332;
	private static final String ACTION_CLOSE = "com.godot.game.online.CLOSE_ROOM";

	private OnlineRoomManager manager;

	public static void start(Context context) {
		Intent intent = new Intent(context, OnlineRoomService.class);
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
			context.startForegroundService(intent);
		} else {
			context.startService(intent);
		}
	}

	@Override
	public void onCreate() {
		super.onCreate();
		manager = OnlineRoomPreferences.manager(this);
		createChannel();
		manager.addListener(this);
	}

	@Override
	public int onStartCommand(Intent intent, int flags, int startId) {
		if (intent != null && ACTION_CLOSE.equals(intent.getAction())) {
			manager.closeRoom();
		}
		OnlineRoomManager.Snapshot snapshot = manager.snapshot();
		Notification notification = buildNotification(snapshot);
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
			startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
		} else {
			startForeground(NOTIFICATION_ID, notification);
		}
		if (snapshot.phase == OnlineRoomManager.Phase.IDLE || snapshot.phase == OnlineRoomManager.Phase.FAILED) {
			stopSelf();
		}
		return START_NOT_STICKY;
	}

	@Override
	public void onRoomStateChanged(OnlineRoomManager.Snapshot snapshot) {
		if (snapshot.phase == OnlineRoomManager.Phase.IDLE || snapshot.phase == OnlineRoomManager.Phase.FAILED) {
			stopSelf();
			return;
		}
		NotificationManager notifications = getSystemService(NotificationManager.class);
		if (notifications != null) {
			notifications.notify(NOTIFICATION_ID, buildNotification(snapshot));
		}
	}

	/** dataSync 前台服务在 Android 15 上有累计时长上限；到时关房，避免被系统判定为 ANR。 */
	@Override
	public void onTimeout(int startId, int fgsType) {
		manager.closeRoom();
		stopSelf();
	}

	@Override
	public void onDestroy() {
		manager.removeListener(this);
		// 服务被系统或用户结束时一并关房，不留下无人维护的 frp 映射。
		OnlineRoomManager.Phase phase = manager.snapshot().phase;
		if (phase == OnlineRoomManager.Phase.OPEN || phase == OnlineRoomManager.Phase.STARTING) {
			manager.closeRoom();
		}
		super.onDestroy();
	}

	@Override
	public IBinder onBind(Intent intent) {
		return null;
	}

	private Notification buildNotification(OnlineRoomManager.Snapshot snapshot) {
		Intent open = new Intent(this, GameSettingsActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
		PendingIntent openIntent = PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
		Intent close = new Intent(this, OnlineRoomService.class).setAction(ACTION_CLOSE);
		PendingIntent closeIntent = PendingIntent.getService(this, 1, close, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
		String text = snapshot.room == null
			? getString(R.string.online_room_notification_starting)
			: getString(R.string.online_room_notification_open, snapshot.room.name, snapshot.server + ":" + snapshot.room.port);
		Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
			? new Notification.Builder(this, CHANNEL_ID)
			: new Notification.Builder(this);
		return builder
			.setSmallIcon(R.drawable.ic_groups_24)
			.setContentTitle(getString(R.string.online_room_notification_title))
			.setContentText(text)
			.setStyle(new Notification.BigTextStyle().bigText(text))
			.setContentIntent(openIntent)
			.setOngoing(true)
			.setOnlyAlertOnce(true)
			.addAction(new Notification.Action.Builder(R.drawable.ic_close_24, getString(R.string.online_room_close), closeIntent).build())
			.build();
	}

	private void createChannel() {
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
			return;
		}
		NotificationManager notifications = getSystemService(NotificationManager.class);
		if (notifications != null) {
			notifications.createNotificationChannel(new NotificationChannel(CHANNEL_ID, getString(R.string.online_room_notification_channel), NotificationManager.IMPORTANCE_LOW));
		}
	}
}
