package com.drawbridge.app;

import android.app.Activity;
import android.content.Intent;
import android.graphics.*;
import android.graphics.pdf.PdfDocument;
import android.net.Uri;
import android.os.Bundle;
import android.provider.Settings;
import android.util.Base64;
import android.view.*;
import android.widget.*;

import com.neovisionaries.ws.client.*;
import org.json.*;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;

public class MainActivity extends Activity {
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private EditText serverField, codeField;
    private TextView status;
    private DrawView board;
    private LinearLayout rootLayout, topBar;
    private HorizontalScrollView toolScroll;
    private WebSocket socket;
    private String clientId, roomCode;
    private static final int SAVE_PDF = 7, PICK_IMAGE = 8, SAVE_IMAGE = 9;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        rootLayout = new LinearLayout(this); rootLayout.setOrientation(LinearLayout.VERTICAL); rootLayout.setPadding(20,16,20,16); rootLayout.setBackgroundColor(Color.rgb(246,247,249));
        topBar = new LinearLayout(this); topBar.setGravity(Gravity.CENTER_VERTICAL);
        TextView title = new TextView(this); title.setText("Drawbridge  ·  ANDROID PEN"); title.setTextSize(20); title.setTextColor(Color.rgb(37,51,66)); title.setTypeface(null,1);
        serverField = field("http://127.0.0.1:3000"); codeField = field(""); codeField.setHint("6자리 코드");
        Button connection=button("연결 설정");
        status = new TextView(this); status.setText("연결 준비"); status.setPadding(14,0,8,0);
        topBar.addView(title,new LinearLayout.LayoutParams(0,55,1));topBar.addView(connection);topBar.addView(status);
        LinearLayout tools=new LinearLayout(this);tools.setGravity(Gravity.CENTER_VERTICAL);
        Button undo=button("↶ 되돌리기"),tool=button("펜 ▾"),color=button("색상 ▾"),width=button("굵기 4"),zoomOut=button("−"),zoomReset=button("100%"),zoomIn=button("+"),more=button("더보기 ▾");
        tools.addView(undo);tools.addView(tool);tools.addView(color);tools.addView(width);tools.addView(zoomOut);tools.addView(zoomReset);tools.addView(zoomIn);tools.addView(more);
        toolScroll=new HorizontalScrollView(this);toolScroll.addView(tools,new HorizontalScrollView.LayoutParams(-2,-2));
        board = new DrawView(); rootLayout.addView(topBar);rootLayout.addView(toolScroll);rootLayout.addView(board,new LinearLayout.LayoutParams(-1,0,1));setContentView(rootLayout);
        connection.setOnClickListener(v->showConnectionDialog());undo.setOnClickListener(v->undo());tool.setOnClickListener(v->showToolDialog(tool));color.setOnClickListener(v->showColorDialog());width.setOnClickListener(v->showWidthDialog(width));more.setOnClickListener(v->showMoreDialog());
        zoomOut.setOnClickListener(v->{board.zoom=Math.max(.5f,board.zoom/1.25f);board.invalidate();status.setText("확대 "+(int)(board.zoom*100)+"%");});zoomReset.setOnClickListener(v->{board.zoom=1;board.invalidate();status.setText("확대 100%");});zoomIn.setOnClickListener(v->{board.zoom=Math.min(4,board.zoom*1.25f);board.invalidate();status.setText("확대 "+(int)(board.zoom*100)+"%");});
        handleInvite(getIntent());
    }

    private EditText field(String value){ EditText e=new EditText(this);e.setText(value);e.setSingleLine();e.setTextSize(13);return e; }
    private Button button(String text){ Button b=new Button(this);b.setText(text);return b; }
    private void showConnectionDialog(){LinearLayout fields=new LinearLayout(this);fields.setOrientation(LinearLayout.VERTICAL);fields.setPadding(36,8,36,0);EditText address=field(serverField.getText().toString()),room=field(codeField.getText().toString());address.setHint("Mac 앱에 표시된 서버 주소");room.setHint("6자리 참여 코드");fields.addView(address);fields.addView(room);new android.app.AlertDialog.Builder(this).setTitle("세션 참여").setMessage("Mac에서 초대 QR을 스캔하는 방법을 권장합니다. 직접 연결할 때만 아래 항목을 입력하세요.").setView(fields).setPositiveButton("참여",(d,w)->{serverField.setText(address.getText());codeField.setText(room.getText());joinRoom(room.getText().toString().trim());}).setNegativeButton("취소",null).show();}
    private void showToolDialog(Button button){String[] items={"펜","마커","형광펜","지우개"};new android.app.AlertDialog.Builder(this).setTitle("필기 도구").setSingleChoiceItems(items,board.eraserMode?3:board.currentStyle.equals("marker")?1:board.currentStyle.equals("highlighter")?2:0,(d,which)->{board.eraserMode=which==3;if(which<3)board.currentStyle=new String[]{"pen","marker","highlighter"}[which];button.setText(items[which]+" ▾");status.setText(items[which]+" 모드");d.dismiss();}).show();}
    private void showColorDialog(){String[] items={"검정","빨강","파랑","초록"};int[] colors={Color.rgb(37,51,66),Color.rgb(225,70,70),Color.rgb(60,100,225),Color.rgb(45,155,115)};new android.app.AlertDialog.Builder(this).setTitle("펜 색상").setItems(items,(d,which)->{board.currentColor=colors[which];status.setText(items[which]+" 선택");}).show();}
    private void showWidthDialog(Button button){SeekBar slider=new SeekBar(this);slider.setMax(15);slider.setProgress((int)board.currentWidth-1);slider.setPadding(40,20,40,20);new android.app.AlertDialog.Builder(this).setTitle("펜 굵기").setView(slider).setPositiveButton("적용",(d,w)->{board.currentWidth=slider.getProgress()+1;button.setText("굵기 "+(int)board.currentWidth);}).setNegativeButton("취소",null).show();}
    private void showMoreDialog(){String[] items={"전체 지우기","이미지 추가","화면 위 필기","PNG 저장","PDF 저장"};new android.app.AlertDialog.Builder(this).setTitle("보드 작업").setItems(items,(d,which)->{if(which==0)new android.app.AlertDialog.Builder(this).setMessage("모든 필기를 지울까요?").setPositiveButton("지우기",(x,w)->sendSimple("clear")).setNegativeButton("취소",null).show();else if(which==1)startActivityForResult(new Intent(Intent.ACTION_OPEN_DOCUMENT).setType("image/*").addCategory(Intent.CATEGORY_OPENABLE),PICK_IMAGE);else if(which==2)toggleOverlay();else if(which==3)startActivityForResult(new Intent(Intent.ACTION_CREATE_DOCUMENT).setType("image/png").putExtra(Intent.EXTRA_TITLE,"drawbridge.png"),SAVE_IMAGE);else{Intent i=new Intent(Intent.ACTION_CREATE_DOCUMENT).setType("application/pdf").putExtra(Intent.EXTRA_TITLE,"drawbridge.pdf");startActivityForResult(i,SAVE_PDF);}}).show();}
    private void toggleOverlay(){board.overlayMode=!board.overlayMode;topBar.setVisibility(board.overlayMode?View.GONE:View.VISIBLE);toolScroll.setVisibility(board.overlayMode?View.GONE:View.VISIBLE);rootLayout.setBackgroundColor(board.overlayMode?Color.TRANSPARENT:Color.rgb(246,247,249));board.setBackgroundColor(board.overlayMode?Color.TRANSPARENT:Color.WHITE);board.invalidate();}
    private String base(){ return serverField.getText().toString().trim().replaceAll("/$",""); }
    private void createRoom(){ io.execute(() -> { try { JSONObject r=post("/api/create",new JSONObject()); runOnUiThread(()->{codeField.setText(r.optString("code"));joinRoom(r.optString("code"));}); } catch(Exception e){showError(e);} }); }
    private void joinRoom(String code){ if(!code.matches("\\d{6}")){status.setText("코드를 확인하세요");return;} io.execute(() -> { try { JSONObject r=post("/api/join",new JSONObject().put("code",code));clientId=r.getString("id");roomCode=code;connectSocket(); } catch(Exception e){showError(e);} }); }
    private JSONObject post(String path, JSONObject body) throws Exception {
        HttpURLConnection c=(HttpURLConnection)new URL(base()+path).openConnection();c.setRequestMethod("POST");c.setRequestProperty("Content-Type","application/json");c.setDoOutput(true);try(OutputStream out=c.getOutputStream()){out.write(body.toString().getBytes(StandardCharsets.UTF_8));}
        InputStream in=c.getResponseCode()<400?c.getInputStream():c.getErrorStream();String text=new String(in.readAllBytes(),StandardCharsets.UTF_8);JSONObject result=new JSONObject(text);if(c.getResponseCode()>=400)throw new IOException(result.optString("error","연결 실패"));return result;
    }
    private void connectSocket() throws Exception {
        if(socket!=null)socket.disconnect();String ws=base().replaceFirst("^http","ws")+"/ws?code="+roomCode+"&id="+clientId;
        socket=new WebSocketFactory().createSocket(ws).setPingInterval(15000).addListener(new WebSocketAdapter(){
            @Override public void onConnected(WebSocket w, Map<String,List<String>> h){runOnUiThread(()->status.setText("● "+roomCode+" 연결됨"));}
            @Override public void onTextMessage(WebSocket w,String text){runOnUiThread(()->board.receive(text));}
            @Override public void onDisconnected(WebSocket w,WebSocketFrame s,WebSocketFrame c,boolean server){runOnUiThread(()->status.setText("연결 끊김"));}
        });socket.connect();board.sender=json->{if(socket!=null&&socket.isOpen())socket.sendText(json);};
    }
    private void showError(Exception e){runOnUiThread(()->status.setText(e.getMessage()));}
    private void sendEvent(JSONObject value){if(socket!=null&&socket.isOpen())socket.sendText(value.toString());}
    private void sendSimple(String type){try{sendEvent(new JSONObject().put("type",type));}catch(Exception ignored){}}
    private void undo(){sendSimple("undo");status.setText("마지막 필기 되돌림");}
    @Override public boolean onKeyDown(int keyCode, KeyEvent event){
        if(event.isCtrlPressed()&&keyCode==KeyEvent.KEYCODE_Z){undo();return true;}
        if(event.isCtrlPressed()&&keyCode==KeyEvent.KEYCODE_P){board.eraserMode=false;board.currentStyle="pen";status.setText("펜 모드");return true;}
        if(event.isCtrlPressed()&&keyCode==KeyEvent.KEYCODE_E){board.eraserMode=true;status.setText("선 지우개 모드");return true;}
        if(event.isCtrlPressed()&&(keyCode==KeyEvent.KEYCODE_PLUS||keyCode==KeyEvent.KEYCODE_EQUALS)){board.zoom=Math.min(4,board.zoom*1.25f);board.invalidate();return true;}
        if(event.isCtrlPressed()&&keyCode==KeyEvent.KEYCODE_MINUS){board.zoom=Math.max(.5f,board.zoom/1.25f);board.invalidate();return true;}
        if(event.isCtrlPressed()&&keyCode==KeyEvent.KEYCODE_0){board.zoom=1;board.invalidate();return true;}
        return super.onKeyDown(keyCode,event);
    }
    @Override protected void onNewIntent(Intent intent){super.onNewIntent(intent);setIntent(intent);handleInvite(intent);}
    private void handleInvite(Intent intent){
        Uri link=intent.getData();if(link==null||!"drawbridge".equals(link.getScheme()))return;
        String server=link.getQueryParameter("server"),room=link.getQueryParameter("room");
        if(server!=null&&!server.isBlank())serverField.setText(server);
        if(room!=null&&room.matches("\\d{6}")){codeField.setText(room);joinRoom(room);}
    }
    @Override protected void onActivityResult(int request,int result,Intent data){super.onActivityResult(request,result,data);if(result!=RESULT_OK||data==null)return;if(request==SAVE_PDF)io.execute(()->{try{writePdf(data.getData());runOnUiThread(()->Toast.makeText(this,"PDF를 저장했습니다",Toast.LENGTH_SHORT).show());}catch(Exception e){showError(e);}});else if(request==PICK_IMAGE)io.execute(()->{try{Bitmap raw=BitmapFactory.decodeStream(getContentResolver().openInputStream(data.getData()));float scale=Math.min(1f,Math.min(1600f/raw.getWidth(),1000f/raw.getHeight()));Bitmap image=Bitmap.createScaledBitmap(raw,Math.max(1,(int)(raw.getWidth()*scale)),Math.max(1,(int)(raw.getHeight()*scale)),true);ByteArrayOutputStream bytes=new ByteArrayOutputStream();image.compress(Bitmap.CompressFormat.JPEG,85,bytes);runOnUiThread(()->board.setBoardBackground(image));sendEvent(new JSONObject().put("type","background").put("image","data:image/jpeg;base64,"+Base64.encodeToString(bytes.toByteArray(),Base64.NO_WRAP)));}catch(Exception e){showError(e);}});else if(request==SAVE_IMAGE)io.execute(()->{try{Bitmap bitmap=board.renderBitmap(1920,1080);try(OutputStream out=getContentResolver().openOutputStream(data.getData())){bitmap.compress(Bitmap.CompressFormat.PNG,100,out);}runOnUiThread(()->Toast.makeText(this,"PNG를 저장했습니다",Toast.LENGTH_SHORT).show());}catch(Exception e){showError(e);}});}
    private void writePdf(Uri uri)throws Exception{PdfDocument doc=new PdfDocument();PdfDocument.Page page=doc.startPage(new PdfDocument.PageInfo.Builder(1920,1080,1).create());board.drawForExport(page.getCanvas(),1920,1080);doc.finishPage(page);try(OutputStream out=getContentResolver().openOutputStream(uri)){doc.writeTo(out);}doc.close();}
    @Override protected void onDestroy(){if(socket!=null)socket.disconnect();io.shutdownNow();super.onDestroy();}

    interface Sender { void send(String json); }
    class DrawView extends View {
        final List<Stroke> strokes=new ArrayList<>(); Stroke current; Sender sender; Bitmap background,screenFrame; boolean eraserMode,overlayMode;int currentColor=Color.rgb(37,51,66);float currentWidth=4,zoom=1;String currentStyle="pen";
        final Paint dot=new Paint(1); long lastSend;boolean gestureZooming;
        final ScaleGestureDetector scaleDetector=new ScaleGestureDetector(MainActivity.this,new ScaleGestureDetector.SimpleOnScaleGestureListener(){
            @Override public boolean onScaleBegin(ScaleGestureDetector detector){gestureZooming=true;finishCurrentStroke();return true;}
            @Override public boolean onScale(ScaleGestureDetector detector){zoom=Math.max(.5f,Math.min(4,zoom*detector.getScaleFactor()));invalidate();status.setText("확대 "+(int)(zoom*100)+"%");return true;}
        });
        DrawView(){super(MainActivity.this);setBackgroundColor(Color.WHITE);setLayerType(View.LAYER_TYPE_SOFTWARE,null);}
        @Override protected void onDraw(Canvas c){super.onDraw(c);c.save();c.scale(zoom,zoom,getWidth()/2f,getHeight()/2f);drawBackground(c,getWidth(),getHeight());drawStrokes(c,getWidth(),getHeight());c.restore();}
        void drawForExport(Canvas c,float w,float h){c.drawColor(Color.WHITE);drawBackground(c,w,h);drawStrokes(c,w,h);}
        Bitmap renderBitmap(int w,int h){Bitmap out=Bitmap.createBitmap(w,h,Bitmap.Config.ARGB_8888);drawForExport(new Canvas(out),w,h);return out;}
        void setBoardBackground(Bitmap value){background=value;invalidate();}
        void drawBackground(Canvas c,float w,float h){drawBitmapFit(c,screenFrame,w,h);drawBitmapFit(c,background,w,h);}
        void drawBitmapFit(Canvas c,Bitmap value,float w,float h){if(value==null)return;float scale=Math.min(w/value.getWidth(),h/value.getHeight()),dw=value.getWidth()*scale,dh=value.getHeight()*scale;c.drawBitmap(value,null,new RectF((w-dw)/2,(h-dh)/2,(w+dw)/2,(h+dh)/2),dot);}
        void drawStrokes(Canvas c,float w,float h){synchronized(strokes){for(Stroke s:strokes){dot.setColor(s.color);dot.setAlpha(s.style.equals("highlighter")?76:255);dot.setStyle(Paint.Style.STROKE);dot.setStrokeCap(s.style.equals("marker")?Paint.Cap.SQUARE:Paint.Cap.ROUND);dot.setStrokeJoin(Paint.Join.ROUND);for(int i=1;i<s.points.size();i++){PointF3 a=s.points.get(i-1),b=s.points.get(i);dot.setStrokeWidth(s.width*(s.style.equals("highlighter")?3:1)*w/1600f*(.4f+b.p*1.2f));c.drawLine(a.x*w,a.y*h,b.x*w,b.y*h,dot);}if(s.points.size()==1){PointF3 p=s.points.get(0);dot.setStyle(Paint.Style.FILL);c.drawCircle(p.x*w,p.y*h,s.width/2,dot);}dot.setAlpha(255);}}}
        float nx(float x){return ((x-getWidth()/2f)/zoom+getWidth()/2f)/getWidth();}float ny(float y){return ((y-getHeight()/2f)/zoom+getHeight()/2f)/getHeight();}
        @Override public boolean onTouchEvent(android.view.MotionEvent e){if(socket==null||!socket.isOpen())return true;scaleDetector.onTouchEvent(e);int action=e.getActionMasked();if(e.getPointerCount()>1||gestureZooming||action==MotionEvent.ACTION_POINTER_DOWN||action==MotionEvent.ACTION_POINTER_UP){if(action==MotionEvent.ACTION_UP||action==MotionEvent.ACTION_CANCEL)gestureZooming=false;return true;}if(action==MotionEvent.ACTION_UP||action==MotionEvent.ACTION_CANCEL)gestureZooming=false;if(eraserMode){if(action==MotionEvent.ACTION_DOWN||action==MotionEvent.ACTION_MOVE){long now=System.currentTimeMillis();if(now-lastSend>35){try{sender.send(new JSONObject().put("type","erase").put("point",new JSONArray().put(nx(e.getX())).put(ny(e.getY()))).put("radius",.025/zoom).toString());}catch(Exception ignored){}lastSend=now;}}return true;}if(action==MotionEvent.ACTION_DOWN){current=new Stroke(UUID.randomUUID().toString(),currentColor,currentWidth,currentStyle);strokes.add(current);}if(current!=null&&(action==MotionEvent.ACTION_DOWN||action==MotionEvent.ACTION_MOVE)){for(int i=0;i<e.getHistorySize();i++)current.points.add(new PointF3(nx(e.getHistoricalX(i)),ny(e.getHistoricalY(i)),Math.max(.05f,e.getHistoricalPressure(i))));current.points.add(new PointF3(nx(e.getX()),ny(e.getY()),Math.max(.05f,e.getPressure())));invalidate();if(System.currentTimeMillis()-lastSend>35){sendCurrent();lastSend=System.currentTimeMillis();}}if(current!=null&&(action==MotionEvent.ACTION_UP||action==MotionEvent.ACTION_CANCEL))finishCurrentStroke();return true;}
        void finishCurrentStroke(){if(current!=null){sendCurrent();current=null;}}
        void sendCurrent(){try{JSONObject s=current.json();sender.send(new JSONObject().put("type","stroke").put("stroke",s).toString());}catch(Exception ignored){}}
        void receive(String text){try{JSONObject m=new JSONObject(text),finalMessage=m;String type=m.optString("type");if(type.equals("state")){strokes.clear();JSONArray a=m.getJSONArray("strokes");for(int i=0;i<a.length();i++)strokes.add(Stroke.from(a.getJSONObject(i)));invalidate();}else if(type.equals("stroke")){Stroke incoming=Stroke.from(m.getJSONObject("stroke"));for(int i=0;i<strokes.size();i++)if(strokes.get(i).id.equals(incoming.id)){strokes.set(i,incoming);invalidate();return;}strokes.add(incoming);invalidate();}else if(type.equals("background")){String value=m.getString("image");byte[] bytes=Base64.decode(value.substring(value.indexOf(',')+1),Base64.DEFAULT);setBoardBackground(BitmapFactory.decodeByteArray(bytes,0,bytes.length));}else if(type.equals("background-clear")){setBoardBackground(null);}else if(type.equals("frame")){String value=m.getString("image");byte[] bytes=Base64.decode(value.substring(value.indexOf(',')+1),Base64.DEFAULT);screenFrame=BitmapFactory.decodeByteArray(bytes,0,bytes.length);status.setText("● Mac 화면 수신 중");invalidate();}else if(type.equals("share-stop")){screenFrame=null;status.setText("● "+roomCode+" 연결됨");invalidate();}}catch(Exception ignored){}}
    }
    static class PointF3 {float x,y,p;PointF3(float x,float y,float p){this.x=x;this.y=y;this.p=p;}}
    static class Stroke {String id,style;int color;float width;List<PointF3> points=new ArrayList<>();Stroke(String id,int color,float width,String style){this.id=id;this.color=color;this.width=width;this.style=style;}
        JSONObject json()throws Exception{JSONObject o=new JSONObject().put("id",id).put("color",String.format("#%06X",0xFFFFFF&color)).put("width",width).put("style",style);JSONArray a=new JSONArray();for(PointF3 p:points)a.put(new JSONArray().put(p.x).put(p.y).put(p.p));return o.put("points",a);}
        static Stroke from(JSONObject o)throws Exception{Stroke s=new Stroke(o.getString("id"),Color.parseColor(o.getString("color")),(float)o.getDouble("width"),o.optString("style","pen"));JSONArray a=o.getJSONArray("points");for(int i=0;i<a.length();i++){JSONArray p=a.getJSONArray(i);s.points.add(new PointF3((float)p.getDouble(0),(float)p.getDouble(1),(float)p.getDouble(2)));}return s;}}
}
