//! Sound: the speaker (ES8311) and the microphones (ES7210), both at 24 kHz, 16 bits, mono.
//!
//! The two chips are set up by Espressif's codec component (C); this file wraps it. Sound
//! has a thread of its own, so playing or recording never stops the eyes: ask through a
//! `Sound` (the badge hands one to the app) and, for a recording, wait for `Event::Heard`.

// Not everything here is used by the starting app; it is here for the next one.
#![allow(dead_code)]

use core::ffi::c_void;
use core::ptr::null_mut;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Arc;

use anyhow::{anyhow, bail, Result};
use esp_idf_svc::sys::*;

use crate::badge::Event;
use crate::bus::I2c;

/// Samples a second, in and out.
pub const RATE: u32 = 24_000;

// The pins (also in board.rs).
const MCLK: i32 = 16;
const BCLK: i32 = 9;
const WS: i32 = 45;
const DOUT: i32 = 8;
const DIN: i32 = 10;
const AMPLIFIER: i16 = 46;

/// What the microphone heard.
#[derive(Clone)]
pub struct Recording {
    /// 24 kHz, mono.
    pub samples: Arc<Vec<i16>>,
}

impl Recording {
    pub fn seconds(&self) -> f32 {
        self.samples.len() as f32 / RATE as f32
    }

    /// The loudest moment, 0 (silence) to 100 (as loud as the microphone goes).
    pub fn loudest(&self) -> u32 {
        loudest(&self.samples)
    }

    /// The recording as a WAV file, e.g. to send to a speech-to-text service.
    pub fn wav(&self) -> Vec<u8> {
        let bytes = self.samples.len() as u32 * 2;
        let mut wav = Vec::with_capacity(44 + bytes as usize);
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + bytes).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes()); // PCM
        wav.extend_from_slice(&1u16.to_le_bytes()); // mono
        wav.extend_from_slice(&RATE.to_le_bytes());
        wav.extend_from_slice(&(RATE * 2).to_le_bytes());
        wav.extend_from_slice(&2u16.to_le_bytes());
        wav.extend_from_slice(&16u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&bytes.to_le_bytes());
        for sample in self.samples.iter() {
            wav.extend_from_slice(&sample.to_le_bytes());
        }
        wav
    }
}

impl core::fmt::Debug for Recording {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(f, "Recording({:.1} s, loudest {}%)", self.seconds(), self.loudest())
    }
}

impl PartialEq for Recording {
    fn eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.samples, &other.samples)
    }
}

enum Request {
    Tone { hz: u32, ms: u32 },
    Play(Arc<Vec<i16>>),
    Listen { ms: u32 },
    Volume(u8),
    Meter(bool),
}

/// The app's handle on sound. Every call returns at once.
#[derive(Clone)]
pub struct Sound {
    requests: Option<Sender<Request>>,
}

impl Sound {
    /// A handle that does nothing, for a badge whose sound did not start.
    pub fn silent() -> Self {
        Sound { requests: None }
    }

    fn ask(&self, request: Request) {
        if let Some(requests) = &self.requests {
            let _ = requests.send(request);
        }
    }

    /// A plain tone: `hz` is the pitch (440 is the A above middle C), `ms` how long.
    pub fn beep(&self, hz: u32, ms: u32) {
        self.ask(Request::Tone { hz, ms });
    }

    /// Play samples: 24 kHz, mono.
    pub fn play(&self, samples: Arc<Vec<i16>>) {
        self.ask(Request::Play(samples));
    }

    /// Record for `ms` milliseconds; the app then gets `Event::Heard`.
    pub fn listen(&self, ms: u32) {
        self.ask(Request::Listen { ms });
    }

    /// Speaker volume, 0 to 100.
    pub fn volume(&self, percent: u8) {
        self.ask(Request::Volume(percent));
    }

    /// Keep the microphone open and report how loud it is, five times a second, as
    /// `Event::Loudness`. Off, the microphone only runs while recording.
    pub fn meter(&self, on: bool) {
        self.ask(Request::Meter(on));
    }
}

struct Codecs {
    speaker: esp_codec_dev_handle_t,
    microphone: esp_codec_dev_handle_t,
    microphone_open: bool,
    volume: u8,
}

// The handles are only ever used from the sound thread.
unsafe impl Send for Codecs {}

impl Codecs {
    fn new(i2c_bus: i2c_master_bus_handle_t) -> Result<Self> {
        unsafe {
            // One I2S port, both ways: plain stereo frames out to the speaker chip, four
            // slots in from the microphone chip.
            let mut channel: i2s_chan_config_t = core::mem::zeroed();
            channel.id = i2s_port_t_I2S_NUM_0;
            channel.role = i2s_role_t_I2S_ROLE_MASTER;
            channel.dma_desc_num = 6;
            channel.dma_frame_num = 240;
            channel.__bindgen_anon_1.auto_clear_after_cb = true;
            let mut tx: i2s_chan_handle_t = null_mut();
            let mut rx: i2s_chan_handle_t = null_mut();
            esp!(i2s_new_channel(&channel, &mut tx, &mut rx))?;

            let mut out: i2s_std_config_t = core::mem::zeroed();
            out.clk_cfg.sample_rate_hz = RATE;
            out.clk_cfg.clk_src = soc_periph_i2s_clk_src_t_I2S_CLK_SRC_DEFAULT;
            out.clk_cfg.mclk_multiple = i2s_mclk_multiple_t_I2S_MCLK_MULTIPLE_256;
            out.slot_cfg.data_bit_width = i2s_data_bit_width_t_I2S_DATA_BIT_WIDTH_16BIT;
            out.slot_cfg.slot_bit_width = i2s_slot_bit_width_t_I2S_SLOT_BIT_WIDTH_AUTO;
            out.slot_cfg.slot_mode = i2s_slot_mode_t_I2S_SLOT_MODE_STEREO;
            out.slot_cfg.slot_mask = i2s_std_slot_mask_t_I2S_STD_SLOT_BOTH;
            out.slot_cfg.ws_width = 16;
            out.slot_cfg.bit_shift = true;
            out.slot_cfg.left_align = true;
            out.gpio_cfg.mclk = MCLK;
            out.gpio_cfg.bclk = BCLK;
            out.gpio_cfg.ws = WS;
            out.gpio_cfg.dout = DOUT;
            out.gpio_cfg.din = -1;
            esp!(i2s_channel_init_std_mode(tx, &out))?;

            let mut input: i2s_tdm_config_t = core::mem::zeroed();
            input.clk_cfg.sample_rate_hz = RATE;
            input.clk_cfg.clk_src = soc_periph_i2s_clk_src_t_I2S_CLK_SRC_DEFAULT;
            input.clk_cfg.mclk_multiple = i2s_mclk_multiple_t_I2S_MCLK_MULTIPLE_256;
            input.clk_cfg.bclk_div = 8;
            input.slot_cfg.data_bit_width = i2s_data_bit_width_t_I2S_DATA_BIT_WIDTH_16BIT;
            input.slot_cfg.slot_bit_width = i2s_slot_bit_width_t_I2S_SLOT_BIT_WIDTH_AUTO;
            input.slot_cfg.slot_mode = i2s_slot_mode_t_I2S_SLOT_MODE_STEREO;
            input.slot_cfg.slot_mask = i2s_tdm_slot_mask_t_I2S_TDM_SLOT0
                | i2s_tdm_slot_mask_t_I2S_TDM_SLOT1
                | i2s_tdm_slot_mask_t_I2S_TDM_SLOT2
                | i2s_tdm_slot_mask_t_I2S_TDM_SLOT3;
            input.slot_cfg.bit_shift = true;
            input.gpio_cfg.mclk = MCLK;
            input.gpio_cfg.bclk = BCLK;
            input.gpio_cfg.ws = WS;
            input.gpio_cfg.dout = -1;
            input.gpio_cfg.din = DIN;
            esp!(i2s_channel_init_tdm_mode(rx, &input))?;
            esp!(i2s_channel_enable(tx))?;
            esp!(i2s_channel_enable(rx))?;

            let mut i2s: audio_codec_i2s_cfg_t = core::mem::zeroed();
            i2s.port = 0;
            i2s.rx_handle = rx as *mut c_void;
            i2s.tx_handle = tx as *mut c_void;
            let data = audio_codec_new_i2s_data(&mut i2s);

            // The chips' addresses, in the codec component's 8-bit spelling.
            let mut i2c: audio_codec_i2c_cfg_t = core::mem::zeroed();
            i2c.port = 0;
            i2c.bus_handle = i2c_bus as *mut c_void;
            i2c.addr = 0x30; // ES8311 (0x18)
            let speaker_control = audio_codec_new_i2c_ctrl(&mut i2c);
            i2c.addr = 0x80; // ES7210 (0x40)
            let microphone_control = audio_codec_new_i2c_ctrl(&mut i2c);
            let gpio = audio_codec_new_gpio();
            if data.is_null() || speaker_control.is_null() || microphone_control.is_null() || gpio.is_null() {
                bail!("the codec's interfaces could not be made");
            }

            let mut es8311: es8311_codec_cfg_t = core::mem::zeroed();
            es8311.ctrl_if = speaker_control;
            es8311.gpio_if = gpio;
            es8311.codec_mode = esp_codec_dec_work_mode_t_ESP_CODEC_DEV_WORK_MODE_DAC;
            es8311.pa_pin = AMPLIFIER;
            es8311.use_mclk = true;
            es8311.hw_gain.pa_voltage = 5.0;
            es8311.hw_gain.codec_dac_voltage = 3.3;
            let speaker_codec = es8311_codec_new(&mut es8311);

            let mut es7210: es7210_codec_cfg_t = core::mem::zeroed();
            es7210.ctrl_if = microphone_control;
            es7210.mic_selected = 0b1111;
            let microphone_codec = es7210_codec_new(&mut es7210);
            if speaker_codec.is_null() || microphone_codec.is_null() {
                bail!("the speaker or microphone chip did not answer");
            }

            let mut device: esp_codec_dev_cfg_t = core::mem::zeroed();
            device.dev_type = esp_codec_dev_type_t_ESP_CODEC_DEV_TYPE_OUT;
            device.codec_if = speaker_codec;
            device.data_if = data;
            let speaker = esp_codec_dev_new(&mut device);
            device.dev_type = esp_codec_dev_type_t_ESP_CODEC_DEV_TYPE_IN;
            device.codec_if = microphone_codec;
            let microphone = esp_codec_dev_new(&mut device);
            if speaker.is_null() || microphone.is_null() {
                bail!("the sound devices could not be made");
            }
            Ok(Codecs { speaker, microphone, microphone_open: false, volume: 60 })
        }
    }

    fn play(&mut self, samples: &[i16]) -> Result<()> {
        unsafe {
            let mut format: esp_codec_dev_sample_info_t = core::mem::zeroed();
            format.bits_per_sample = 16;
            format.channel = 1;
            format.sample_rate = RATE;
            check(esp_codec_dev_open(self.speaker, &mut format), "open the speaker")?;
            let _ = esp_codec_dev_set_out_vol(self.speaker, self.volume as _);
            // In pieces, so a long sound doesn't hold the driver for seconds at a time.
            let mut result = Ok(());
            for piece in samples.chunks(2400) {
                result = check(
                    esp_codec_dev_write(self.speaker, piece.as_ptr() as *mut c_void, (piece.len() * 2) as i32),
                    "play",
                );
                if result.is_err() {
                    break;
                }
            }
            // Closing switches the amplifier off again: no hiss, less battery.
            let _ = esp_codec_dev_close(self.speaker);
            result
        }
    }

    fn open_microphone(&mut self) -> Result<()> {
        if self.microphone_open {
            return Ok(());
        }
        unsafe {
            let mut format: esp_codec_dev_sample_info_t = core::mem::zeroed();
            format.bits_per_sample = 16;
            format.channel = 4;
            format.channel_mask = 1; // the first microphone only
            format.sample_rate = RATE;
            check(esp_codec_dev_open(self.microphone, &mut format), "open the microphone")?;
            let _ = esp_codec_dev_set_in_channel_gain(self.microphone, 1, 30.0);
        }
        self.microphone_open = true;
        Ok(())
    }

    fn close_microphone(&mut self) {
        if self.microphone_open {
            unsafe {
                let _ = esp_codec_dev_close(self.microphone);
            }
            self.microphone_open = false;
        }
    }

    /// Fill `samples` from the microphone. It must be open.
    fn read(&mut self, samples: &mut [i16]) -> Result<()> {
        for piece in samples.chunks_mut(2400) {
            check(
                unsafe { esp_codec_dev_read(self.microphone, piece.as_mut_ptr() as *mut c_void, (piece.len() * 2) as i32) },
                "record",
            )?;
        }
        Ok(())
    }

    fn listen(&mut self, ms: u32) -> Result<Vec<i16>> {
        self.open_microphone()?;
        let mut samples = vec![0i16; (RATE as u64 * ms as u64 / 1000) as usize];
        self.read(&mut samples).map(|_| samples)
    }
}

/// The loudest sample, 0 to 100.
fn loudest(samples: &[i16]) -> u32 {
    samples.iter().map(|s| s.unsigned_abs() as u32).max().unwrap_or(0) * 100 / 32768
}

fn check(code: i32, doing: &str) -> Result<()> {
    if code == 0 {
        Ok(())
    } else {
        Err(anyhow!("sound: could not {doing} (error {code})"))
    }
}

fn tone(hz: u32, ms: u32) -> Vec<i16> {
    let count = (RATE as u64 * ms.min(5000) as u64 / 1000) as usize;
    let fade = (RATE as usize / 200).min(count / 2).max(1); // 5 ms in and out: no click
    (0..count)
        .map(|i| {
            let wave = (i as f32 * hz as f32 * core::f32::consts::TAU / RATE as f32).sin();
            let edge = (i.min(count - 1 - i) as f32 / fade as f32).min(1.0);
            (wave * edge * 12000.0) as i16
        })
        .collect()
}

/// Start sound on a thread of its own. Recordings arrive on `events` as `Event::Heard`.
pub fn start(i2c: &I2c, events: Sender<Event>) -> Result<Sound> {
    let (requests, queue): (Sender<Request>, Receiver<Request>) = mpsc::channel();
    let mut codecs = Codecs::new(i2c.handle())?;
    std::thread::Builder::new().name("sound".into()).stack_size(8192).spawn(move || {
        let mut metering = false;
        let mut slice = vec![0i16; RATE as usize / 5]; // a fifth of a second
        loop {
            // With the meter on, a request is looked for between two slices of listening;
            // with it off, the thread sleeps until one comes.
            let request = if metering {
                match queue.try_recv() {
                    Ok(request) => Some(request),
                    Err(mpsc::TryRecvError::Empty) => None,
                    Err(mpsc::TryRecvError::Disconnected) => break,
                }
            } else {
                match queue.recv() {
                    Ok(request) => Some(request),
                    Err(_) => break,
                }
            };
            let result = match request {
                Some(Request::Tone { hz, ms }) => codecs.play(&tone(hz, ms)),
                Some(Request::Play(samples)) => codecs.play(&samples),
                Some(Request::Volume(percent)) => {
                    codecs.volume = percent.min(100);
                    Ok(())
                }
                Some(Request::Listen { ms }) => codecs.listen(ms.min(30_000)).map(|samples| {
                    let _ = events.send(Event::Heard(Recording { samples: Arc::new(samples) }));
                }),
                Some(Request::Meter(on)) => {
                    metering = on;
                    Ok(())
                }
                None => codecs.open_microphone().and_then(|_| codecs.read(&mut slice)).map(|_| {
                    let _ = events.send(Event::Loudness(loudest(&slice) as u8));
                }),
            };
            if let Err(error) = result {
                ::log::warn!("{error}");
                metering = false;
            }
            if !metering {
                codecs.close_microphone();
            }
        }
    })?;
    ::log::info!("sound: on");
    Ok(Sound { requests: Some(requests) })
}
