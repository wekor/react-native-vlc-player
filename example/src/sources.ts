// 回归数据源 —— 数据要持续说话：
// 同一批源在每个版本上跑出的结果才有纵向可比性。
// 规矩：已有条目的 URL 与顺序永不修改；新功能只允许追加带版本号的新条目。
export type TestSource = {
  name: string;
  url: string;
  note: string;
  /** 按源覆盖的播放器 props（例:老编码样本需软解） */
  overrides?: { hardwareDecoding?: boolean };
};

export const SOURCES: TestSource[] = [
  {
    name: 'MP4 / HTTPS',
    url: 'https://www.w3schools.com/Html/mov_bbb.mp4',
    note: 'VOD 标准用例，应能拿到 duration，onProgress 持续触发',
  },
  {
    name: 'RTSP (本机摄像头)',
    url: 'rtsp://172.27.1.52:50001/live/0',
    note: '直播源,视频尺寸可能从未被报告;0.5.0 新增:currentTime 应持续走字',
  },
  {
    name: 'HLS m3u8',
    url: 'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8',
    note: 'Apple 官方测试流，自适应码率',
  },
  {
    name: 'HLS (Mux)',
    url: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    note: 'Mux 公开测试流',
  },
  {
    name: 'DASH mpd',
    url: 'https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd',
    note: 'Akamai DASH 测试源',
  },
  {
    name: '多轨 MKV (0.5.0)',
    url: 'https://samples.ffmpeg.org/Matroska/multiple_tracks.mkv',
    note: '新功能:单文件双音轨(英/日)+双字幕(英/日),ffmpeg 官方样本,id 稳定;XVID 老编码需软解',
    overrides: { hardwareDecoding: false },
  },
  {
    name: '坏 URL',
    url: 'https://invalid-host.example.com/nonexistent.mp4',
    note: '应在 ~8s 内触发 onError',
  },
];

/** 外挂字幕测试文件（公网，验证 subtitleUri 加载管道） */
export const EXTERNAL_SUBTITLE_URL =
  'https://raw.githubusercontent.com/andreyvit/subtitle-tools/master/sample.srt';
