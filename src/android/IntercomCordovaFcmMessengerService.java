package io.intercom.android.sdk;

import android.app.ActivityManager;
import android.app.TaskStackBuilder;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

import com.google.firebase.messaging.RemoteMessage;

import java.util.Map;

import io.intercom.android.sdk.fcm.IntercomFcmMessengerService;
import io.intercom.android.sdk.push.IntercomPushClient;

/**
 * Preserves the application launcher beneath an Intercom conversation opened
 * from a notification when Android no longer has an application task.
 */
public class IntercomCordovaFcmMessengerService extends IntercomFcmMessengerService {

    private static final String TAG = "Intercom-Cordova";

    @Override
    public void onMessageReceived(RemoteMessage remoteMessage) {
        Map<String, String> data = remoteMessage.getData();
        IntercomPushClient pushClient = new IntercomPushClient();

        if (!pushClient.isIntercomPush(data)) {
            super.onMessageReceived(remoteMessage);
            return;
        }

        Intent launchIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
        ActivityManager activityManager =
                (ActivityManager) getSystemService(Context.ACTIVITY_SERVICE);

        if (launchIntent != null && !hasApplicationLaunchTask(activityManager, launchIntent)) {
            TaskStackBuilder taskStackBuilder = TaskStackBuilder.create(this);
            taskStackBuilder.addNextIntent(launchIntent);
            pushClient.handlePushWithCustomStack(getApplication(), data, taskStackBuilder);
            Log.d(TAG, "Handled Intercom push with the application launch stack");
            return;
        }

        super.onMessageReceived(remoteMessage);
    }

    private boolean hasApplicationLaunchTask(
            ActivityManager activityManager,
            Intent launchIntent
    ) {
        if (activityManager == null || launchIntent == null || launchIntent.getComponent() == null) {
            return false;
        }

        ComponentName launchComponent = launchIntent.getComponent();
        for (ActivityManager.AppTask appTask : activityManager.getAppTasks()) {
            ActivityManager.RecentTaskInfo taskInfo = appTask.getTaskInfo();
            if (taskInfo != null &&
                    (launchComponent.equals(taskInfo.baseActivity) ||
                            launchComponent.equals(taskInfo.topActivity))) {
                return true;
            }
        }
        return false;
    }
}
