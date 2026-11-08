"""Exercise the file protocol in a real, offscreen STA WPF dispatcher (Windows)."""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
MAIN = r"""
param([string]$Session)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
. (Join-Path $PSScriptRoot 'Transport.ps1')
$window=[Windows.Window]::new()
$window.ShowInTaskbar=$false; $window.ShowActivated=$false; $window.Opacity=0
$window.WindowStartupLocation='Manual'; $window.Left=-20000; $window.Top=-20000
$window.Width=80; $window.Height=80
$state = {
    param($snapshot)
    $bytes = [IO.File]::ReadAllBytes($snapshot.image)
    $id = Send-WorkspaceAction 'select' @{ text=$snapshot.text; bytes=[Convert]::ToBase64String($bytes) }
}
$reply = {
    param($record)
    $null=Send-WorkspaceAction 'acknowledged' @{id=$record.id; ok=$record.ok; error=$record.error}
}
Initialize-WorkspaceTransport $Session $window $state $reply
$null=$window.ShowDialog()
"""


def packet(path, data, unicode_fallback):
    if not unicode_fallback:
        temp=path.with_suffix(".tmp")
        temp.write_bytes(data)
        temp.rename(path)
        return
    path.mkdir()
    encoded=base64.urlsafe_b64encode(data).decode("ascii")
    for start in range(0,len(encoded),112):
        (path/f"{start+1:08d}_{encoded[start:start+112]}").mkdir()
    (path/"complete").mkdir()


@unittest.skipUnless(os.name=="nt","requires Windows WPF")
class WorkspaceWindowsTest(unittest.TestCase):
    def setUp(self):
        (ROOT/".runtime").mkdir(exist_ok=True)
        self.temp=tempfile.TemporaryDirectory(dir=ROOT/".runtime",prefix="测试 & % transport ")
        self.addCleanup(self.temp.cleanup)
        self.project=Path(self.temp.name)
        self.ui=self.project/"workspace"
        self.ui.mkdir()
        shutil.copyfile(ROOT/"workspace"/"Transport.ps1",self.ui/"Transport.ps1")
        (self.ui/"Main.ps1").write_text(MAIN,encoding="utf-8-sig")
        self.sessions=self.project/".runtime"/"workspaces"
        self.sessions.mkdir(parents=True)

    def launch(self, name):
        session=self.sessions/name
        for area in ("state","events","replies","assets","heartbeat"):
            (session/area).mkdir(parents=True)
        process=subprocess.Popen(
            ["powershell.exe","-NoProfile","-NonInteractive","-STA","-ExecutionPolicy","Bypass",
             "-File",str(self.ui/"Main.ps1"),"-Session",str(session)],
            creationflags=subprocess.CREATE_NO_WINDOW,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        def finish():
            (session/"stop").mkdir(exist_ok=True)
            try: process.communicate(timeout=8)
            except subprocess.TimeoutExpired:
                process.kill(); process.communicate()
        self.addCleanup(finish)
        return session, process

    def wait(self,path,process):
        end=time.monotonic()+20
        while not path.exists():
            if process.poll() is not None:
                self.fail(f"WPF exited {process.returncode}: {process.communicate()[1][-1500:]}")
            self.assertLess(time.monotonic(),end,f"Timeout: {path.name}")
            time.sleep(.03)

    def test_real_wpf_latest_snapshot_ack_and_duplicate_launch(self):
        session,process=self.launch("window-one")
        self.wait(session/"ready",process)
        duplicate,other=self.launch("window-two")
        self.wait(duplicate/"redirected",other)
        other.communicate(timeout=6)
        self.assertFalse((duplicate/"ready").exists())

        jpeg=bytes(range(256))*3
        image=session/"assets"/"image-00000001.jpg"
        packet(Path(str(image)+".payload"),jpeg,True)
        snapshot={"text":"测试 %PATH% & ! 💡","image":str(image)}
        packet(session/"state"/"00000001.json",json.dumps(snapshot,ensure_ascii=False).encode(),True)
        event=session/"events"/"00000001.json"
        self.wait(event,process)
        data=json.loads(event.read_text("utf-8"))
        self.assertEqual(data["action"],"select")
        self.assertEqual(data["payload"]["text"],snapshot["text"])
        self.assertEqual(base64.b64decode(data["payload"]["bytes"]),jpeg)

        # A rejected action is reported through the same window callback.
        packet(session/"replies"/"00000001.json",json.dumps({"id":1,"ok":False,"error":"失败"}).encode(),False)
        ack=session/"events"/"00000002.json"
        self.wait(ack,process)
        self.assertEqual(json.loads(ack.read_text("utf-8"))["payload"]["error"],"失败")
        (session/"stop").mkdir()
        process.communicate(timeout=10)
        self.assertEqual(process.returncode,0)
        self.assertTrue((session/"closed").exists())


if __name__=="__main__":
    unittest.main()
