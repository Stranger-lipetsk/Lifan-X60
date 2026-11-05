package tw.com.elead.el830.home;

import android.app.Activity;
import android.os.Bundle;
import android.widget.TextView;

/** Test double for the car Home, used only on a disposable emulator. */
public final class Home extends Activity {
    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        TextView text = new TextView(this);
        text.setText("Fake car Home (emulator only)");
        setContentView(text);
    }
}
