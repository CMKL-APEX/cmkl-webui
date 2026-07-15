<script lang="ts">
	import { getContext, onDestroy, onMount } from 'svelte';
	import { createEventDispatcher } from 'svelte';
	import { toast } from 'svelte-sonner';

	import { models, settings, showCallOverlay } from '$lib/stores';
	import { WEBUI_API_BASE_URL } from '$lib/constants';
	import Tooltip from '$lib/components/common/Tooltip.svelte';

	const dispatch = createEventDispatcher();
	const i18n = getContext('i18n');

	export let eventTarget: EventTarget;
	export let submitPrompt: Function;
	export let stopResponse: Function;
	export let files;
	export let chatId;
	export let modelId;

	const INPUT_SAMPLE_RATE = 16000;
	const INPUT_CHUNK_MS = 200;
	const INPUT_CHUNK_BYTES = (INPUT_SAMPLE_RATE * 2 * INPUT_CHUNK_MS) / 1000;
	const MIN_DECIBELS = -55;

	let wakeLock = null;
	let model = null;

	let loading = true;
	let muted = false;
	let assistantSpeaking = false;
	let rmsLevel = 0;
	let hasStartedSpeaking = false;
	let awaitingResponse = false;
	let transcript = '';

	let audioStream: MediaStream | null = null;
	let captureContext: AudioContext | null = null;
	let playbackContext: AudioContext | null = null;
	let microphoneSource: MediaStreamAudioSourceNode | null = null;
	let analyser: AnalyserNode | null = null;
	let processor: ScriptProcessorNode | null = null;
	let silentGain: GainNode | null = null;
	let detectFrame = 0;

	let realtimeSocket: WebSocket | null = null;
	let socketReady = false;
	let turnActive = false;
	let ignoreAssistantAudio = false;
	let nextPlaybackTime = 0;
	let pendingPcmBytes: number[] = [];

	const getRealtimeSocketUrl = () => {
		const url = new URL(`${WEBUI_API_BASE_URL}/realtime`, window.location.origin);
		url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
		return url.toString();
	};

	const arrayBufferToBase64 = (buffer: ArrayBuffer) => {
		let binary = '';
		const bytes = new Uint8Array(buffer);
		const chunkSize = 0x8000;
		for (let i = 0; i < bytes.length; i += chunkSize) {
			binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
		}
		return btoa(binary);
	};

	const base64ToUint8Array = (value: string) => {
		const binary = atob(value);
		const bytes = new Uint8Array(binary.length);
		for (let i = 0; i < binary.length; i++) {
			bytes[i] = binary.charCodeAt(i);
		}
		return bytes;
	};

	const pcm16ToFloat32 = (pcmBytes: Uint8Array) => {
		const int16 = new Int16Array(
			pcmBytes.buffer,
			pcmBytes.byteOffset,
			Math.floor(pcmBytes.byteLength / 2)
		);
		const float32 = new Float32Array(int16.length);
		for (let i = 0; i < int16.length; i++) {
			float32[i] = Math.max(-1, Math.min(1, int16[i] / 0x8000));
		}
		return float32;
	};

	const float32ToPcm16Bytes = (samples: Float32Array) => {
		const bytes = new Uint8Array(samples.length * 2);
		const view = new DataView(bytes.buffer);
		for (let i = 0; i < samples.length; i++) {
			const sample = Math.max(-1, Math.min(1, samples[i]));
			view.setInt16(i * 2, sample < 0 ? sample * 0x8000 : sample * 0x7fff, true);
		}
		return bytes;
	};

	const resampleFloat32 = (samples: Float32Array, fromRate: number, toRate: number) => {
		if (fromRate === toRate) {
			return samples;
		}

		const ratio = fromRate / toRate;
		const outputLength = Math.max(1, Math.round(samples.length / ratio));
		const output = new Float32Array(outputLength);

		for (let i = 0; i < outputLength; i++) {
			const position = i * ratio;
			const left = Math.floor(position);
			const right = Math.min(left + 1, samples.length - 1);
			const weight = position - left;
			output[i] = samples[left] * (1 - weight) + samples[right] * weight;
		}

		return output;
	};

	const sendRealtimeEvent = (payload: Record<string, any>) => {
		if (!realtimeSocket || realtimeSocket.readyState !== WebSocket.OPEN) {
			return;
		}
		realtimeSocket.send(JSON.stringify(payload));
	};

	const flushPendingAudio = (includeRemainder = false) => {
		while (pendingPcmBytes.length >= INPUT_CHUNK_BYTES) {
			const chunk = new Uint8Array(pendingPcmBytes.splice(0, INPUT_CHUNK_BYTES));
			sendRealtimeEvent({
				type: 'input_audio_buffer.append',
				audio: arrayBufferToBase64(chunk.buffer)
			});
		}

		if (includeRemainder && pendingPcmBytes.length > 0) {
			const chunk = new Uint8Array(pendingPcmBytes.splice(0, pendingPcmBytes.length));
			sendRealtimeEvent({
				type: 'input_audio_buffer.append',
				audio: arrayBufferToBase64(chunk.buffer)
			});
		}
	};

	const calculateRMS = (data: Uint8Array) => {
		let sumSquares = 0;
		for (let i = 0; i < data.length; i++) {
			const normalizedValue = (data[i] - 128) / 128;
			sumSquares += normalizedValue * normalizedValue;
		}
		return Math.sqrt(sumSquares / data.length);
	};

	const updateAssistantStateFromPlayback = () => {
		if (!playbackContext) {
			assistantSpeaking = false;
			return;
		}

		if (playbackContext.currentTime >= nextPlaybackTime - 0.05 && !awaitingResponse) {
			assistantSpeaking = false;
			if (muted) {
				muted = false;
			}
		}
	};

	const queuePlaybackAudio = async (pcmBytes: Uint8Array, sampleRate = 24000) => {
		if (ignoreAssistantAudio || pcmBytes.byteLength === 0) {
			return;
		}

		if (!playbackContext || playbackContext.state === 'closed') {
			playbackContext = new AudioContext();
			nextPlaybackTime = 0;
		}

		if (playbackContext.state === 'suspended') {
			await playbackContext.resume();
		}

		const buffer = playbackContext.createBuffer(1, pcmBytes.byteLength / 2, sampleRate);
		buffer.copyToChannel(pcm16ToFloat32(pcmBytes), 0);

		const source = playbackContext.createBufferSource();
		source.buffer = buffer;
		source.connect(playbackContext.destination);

		const startAt = Math.max(playbackContext.currentTime + 0.02, nextPlaybackTime);
		source.start(startAt);
		nextPlaybackTime = startAt + buffer.duration;
		assistantSpeaking = true;
		loading = false;

		source.onended = () => {
			updateAssistantStateFromPlayback();
		};
	};

	const beginTurn = async () => {
		if (turnActive || muted || !socketReady) {
			return;
		}

		if (assistantSpeaking) {
			await stopAllAudio();
		}

		pendingPcmBytes = [];
		transcript = '';
		ignoreAssistantAudio = false;
		hasStartedSpeaking = true;
		turnActive = true;
		awaitingResponse = false;
		loading = false;

		sendRealtimeEvent({ type: 'input_audio_buffer.commit', final: false });
	};

	const finishTurn = () => {
		if (!turnActive) {
			return;
		}

		flushPendingAudio(true);
		sendRealtimeEvent({ type: 'input_audio_buffer.commit', final: true });

		turnActive = false;
		hasStartedSpeaking = false;
		awaitingResponse = true;
		loading = true;
	};

	const handleRealtimeEvent = async (event: MessageEvent) => {
		if (typeof event.data !== 'string') {
			return;
		}

		let payload;
		try {
			payload = JSON.parse(event.data);
		} catch {
			return;
		}

		switch (payload?.type) {
			case 'session.created':
				loading = false;
				return;
			case 'response.audio.delta': {
				const pcmBytes = base64ToUint8Array(payload.audio ?? '');
				await queuePlaybackAudio(pcmBytes, payload.sample_rate_hz ?? 24000);
				return;
			}
			case 'response.audio.done':
				awaitingResponse = false;
				updateAssistantStateFromPlayback();
				return;
			case 'transcription.delta':
				transcript = `${transcript}${payload.delta ?? ''}`;
				return;
			case 'transcription.done':
				transcript = payload.text ?? transcript;
				return;
			case 'response.done':
			case 'response.completed':
				awaitingResponse = false;
				updateAssistantStateFromPlayback();
				return;
			case 'error': {
				const message = payload?.error?.message ?? payload?.message ?? 'Realtime voice chat failed';
				loading = false;
				awaitingResponse = false;
				toast.error(`${message}`);
				return;
			}
		}
	};

	const connectRealtimeSocket = async () => {
		await new Promise<void>((resolve, reject) => {
			const socket = new WebSocket(getRealtimeSocketUrl());
			realtimeSocket = socket;

			socket.onopen = () => {
				socket.send(JSON.stringify({ type: 'auth', token: localStorage.token }));
				socket.send(JSON.stringify({ type: 'session.update', model: modelId }));
				socketReady = true;
				resolve();
			};

			socket.onmessage = handleRealtimeEvent;

			socket.onerror = () => {
				reject(new Error('Realtime socket connection failed'));
			};

			socket.onclose = (closeEvent) => {
				socketReady = false;
				if ($showCallOverlay && closeEvent.code !== 1000) {
					toast.error($i18n.t('Real-time voice chat disconnected'));
				}
			};
		});
	};

	const analyseAudio = () => {
		if (!analyser) {
			return;
		}

		const domainData = new Uint8Array(analyser.frequencyBinCount);
		const timeDomainData = new Uint8Array(analyser.fftSize);
		let lastSoundTime = Date.now();

		const processFrame = () => {
			if (!analyser || !$showCallOverlay) {
				return;
			}

			if (muted || (assistantSpeaking && !($settings?.voiceInterruption ?? false))) {
				rmsLevel = 0;
			} else {
				analyser.getByteTimeDomainData(timeDomainData);
				analyser.getByteFrequencyData(domainData);
				rmsLevel = calculateRMS(timeDomainData);

				const hasSound = domainData.some((value) => value > 0);
				if (hasSound) {
					if (!hasStartedSpeaking) {
						beginTurn();
					}
					lastSoundTime = Date.now();
				}

				if (hasStartedSpeaking && Date.now() - lastSoundTime > 1200) {
					finishTurn();
				}
			}

			detectFrame = window.requestAnimationFrame(processFrame);
		};

		detectFrame = window.requestAnimationFrame(processFrame);
	};

	const startRecording = async () => {
		audioStream = await navigator.mediaDevices.getUserMedia({
			audio: {
				echoCancellation: true,
				noiseSuppression: true,
				autoGainControl: true
			}
		});

		captureContext = new AudioContext();
		microphoneSource = captureContext.createMediaStreamSource(audioStream);
		analyser = captureContext.createAnalyser();
		analyser.minDecibels = MIN_DECIBELS;
		silentGain = captureContext.createGain();
		silentGain.gain.value = 0;
		processor = captureContext.createScriptProcessor(4096, 1, 1);

		microphoneSource.connect(analyser);
		microphoneSource.connect(processor);
		processor.connect(silentGain);
		silentGain.connect(captureContext.destination);

		processor.onaudioprocess = (audioEvent) => {
			if (!captureContext || !turnActive || muted || !socketReady) {
				return;
			}

			const inputSamples = audioEvent.inputBuffer.getChannelData(0);
			const resampled = resampleFloat32(inputSamples, captureContext.sampleRate, INPUT_SAMPLE_RATE);
			const pcmBytes = float32ToPcm16Bytes(resampled);
			pendingPcmBytes.push(...pcmBytes);
			flushPendingAudio(false);
		};

		analyseAudio();
	};

	const stopAudioStream = async () => {
		if (detectFrame) {
			cancelAnimationFrame(detectFrame);
			detectFrame = 0;
		}

		processor?.disconnect();
		microphoneSource?.disconnect();
		analyser?.disconnect();
		silentGain?.disconnect();

		if (captureContext && captureContext.state !== 'closed') {
			await captureContext.close();
		}

		if (audioStream) {
			audioStream.getTracks().forEach((track) => track.stop());
		}

		processor = null;
		microphoneSource = null;
		analyser = null;
		silentGain = null;
		captureContext = null;
		audioStream = null;
	};

	const stopAllAudio = async () => {
		ignoreAssistantAudio = true;
		assistantSpeaking = false;
		awaitingResponse = false;
		loading = false;
		nextPlaybackTime = 0;

		if (realtimeSocket && realtimeSocket.readyState === WebSocket.OPEN) {
			realtimeSocket.send(JSON.stringify({ type: 'response.cancel' }));
		}

		if (playbackContext && playbackContext.state !== 'closed') {
			await playbackContext.close();
		}

		playbackContext = null;
	};

	const toggleMute = () => {
		muted = !muted;
		if (muted && hasStartedSpeaking) {
			turnActive = false;
			hasStartedSpeaking = false;
			pendingPcmBytes = [];
		}
	};

	const closeOverlay = async () => {
		await stopAllAudio();
		await stopAudioStream();
		if (realtimeSocket) {
			realtimeSocket.close(1000, 'client closed');
			realtimeSocket = null;
		}
		showCallOverlay.set(false);
		dispatch('close');
	};

	const handleKeydown = (e: KeyboardEvent) => {
		if (e.key === 'm' || e.key === 'M') {
			const target = e.target as HTMLElement;
			if (
				target.tagName !== 'INPUT' &&
				target.tagName !== 'TEXTAREA' &&
				!target.isContentEditable
			) {
				e.preventDefault();
				toggleMute();
			}
		}
	};

	onMount(async () => {
		model = $models.find((m) => m.id === modelId);

		try {
			if ('wakeLock' in navigator) {
				wakeLock = await navigator.wakeLock.request('screen').catch(() => null);
			}

			await connectRealtimeSocket();
			await startRecording();
			loading = false;
			document.addEventListener('keydown', handleKeydown);
		} catch (error) {
			console.error(error);
			toast.error($i18n.t('Failed to start real-time voice chat'));
			closeOverlay();
		}
	});

	onDestroy(async () => {
		document.removeEventListener('keydown', handleKeydown);
		await stopAllAudio();
		await stopAudioStream();
		if (realtimeSocket) {
			realtimeSocket.close(1000, 'component destroyed');
			realtimeSocket = null;
		}
		if (wakeLock) {
			await wakeLock.release().catch(() => {});
		}
	});
</script>

{#if $showCallOverlay}
	<div class="max-w-lg w-full h-full max-h-[100dvh] flex flex-col justify-between p-3 md:p-6">
		<div class="flex justify-center items-center flex-1 h-full w-full max-h-full">
			<button
				type="button"
				on:click={() => {
					if (assistantSpeaking) {
						stopAllAudio();
					}
				}}
			>
				{#if loading || awaitingResponse || assistantSpeaking}
					<svg
						class="size-44 text-gray-900 dark:text-gray-400"
						viewBox="0 0 24 24"
						fill="currentColor"
						xmlns="http://www.w3.org/2000/svg"
					>
						<style>
							.spinner_qM83 {
								animation: spinner_8HQG 1.05s infinite;
							}
							.spinner_oXPr {
								animation-delay: 0.1s;
							}
							.spinner_ZTLf {
								animation-delay: 0.2s;
							}
							@keyframes spinner_8HQG {
								0%,
								57.14% {
									animation-timing-function: cubic-bezier(0.33, 0.66, 0.66, 1);
									transform: translate(0);
								}
								28.57% {
									animation-timing-function: cubic-bezier(0.33, 0, 0.66, 0.33);
									transform: translateY(-6px);
								}
								100% {
									transform: translate(0);
								}
							}
						</style>
						<circle class="spinner_qM83" cx="4" cy="12" r="3" />
						<circle class="spinner_qM83 spinner_oXPr" cx="12" cy="12" r="3" />
						<circle class="spinner_qM83 spinner_ZTLf" cx="20" cy="12" r="3" />
					</svg>
				{:else}
					<div
						class="{rmsLevel * 100 > 4
							? ' size-52'
							: rmsLevel * 100 > 2
								? 'size-48'
								: rmsLevel * 100 > 1
									? 'size-44'
									: 'size-40'} transition-all rounded-full bg-cover bg-center bg-no-repeat"
						style={`background-image: url('${WEBUI_API_BASE_URL}/models/model/profile/image?id=${model?.id}&lang=${$i18n.language}&voice=true');`}
					/>
				{/if}
			</button>
		</div>

		<div class="flex flex-col items-center gap-4 pb-4 w-full">
			<div class="text-center">
				<div class="line-clamp-1 text-sm font-medium">
					{#if muted}
						{$i18n.t('Muted')}
					{:else if assistantSpeaking}
						{$i18n.t('Tap to interrupt')}
					{:else if awaitingResponse}
						{$i18n.t('Thinking...')}
					{:else}
						{$i18n.t('Listening...')}
					{/if}
				</div>
				{#if transcript}
					<div class="mt-2 max-w-md text-xs text-gray-500 dark:text-gray-400 line-clamp-2">
						{transcript}
					</div>
				{/if}
			</div>

			<div class="flex items-center justify-center gap-4 z-10">
				<Tooltip content={muted ? $i18n.t('Unmute') + ' (M)' : $i18n.t('Mute') + ' (M)'}>
					<button
						class="p-3 rounded-full transition-colors duration-200 {muted
							? 'bg-red-500 text-white'
							: 'bg-gray-50 dark:bg-gray-900'}"
						type="button"
						aria-label={muted ? $i18n.t('Unmute') : $i18n.t('Mute')}
						on:click={toggleMute}
					>
						{#if muted}
							<svg
								xmlns="http://www.w3.org/2000/svg"
								fill="none"
								viewBox="0 0 24 24"
								stroke-width="1.5"
								stroke="currentColor"
								class="size-5"
							>
								<path
									stroke-linecap="round"
									stroke-linejoin="round"
									d="M12 18.75a6 6 0 0 0 6-6v-1.5m-6 7.5a6 6 0 0 1-6-6v-1.5m6 7.5v3.75m-3.75 0h7.5M12 15.75a3 3 0 0 1-3-3V4.5a3 3 0 1 1 6 0v8.25a3 3 0 0 1-3 3Z"
								/>
								<line
									x1="3"
									y1="3"
									x2="21"
									y2="21"
									stroke="currentColor"
									stroke-width="1.5"
									stroke-linecap="round"
								/>
							</svg>
						{:else}
							<svg
								xmlns="http://www.w3.org/2000/svg"
								fill="none"
								viewBox="0 0 24 24"
								stroke-width="1.5"
								stroke="currentColor"
								class="size-5"
							>
								<path
									stroke-linecap="round"
									stroke-linejoin="round"
									d="M12 18.75a6 6 0 0 0 6-6v-1.5m-6 7.5a6 6 0 0 1-6-6v-1.5m6 7.5v3.75m-3.75 0h7.5M12 15.75a3 3 0 0 1-3-3V4.5a3 3 0 1 1 6 0v8.25a3 3 0 0 1-3 3Z"
								/>
							</svg>
						{/if}
					</button>
				</Tooltip>

				<button
					class="p-3 rounded-full bg-gray-50 dark:bg-gray-900"
					on:click={closeOverlay}
					type="button"
				>
					<svg
						xmlns="http://www.w3.org/2000/svg"
						viewBox="0 0 20 20"
						fill="currentColor"
						class="size-5"
					>
						<path
							d="M6.28 5.22a.75.75 0 0 0-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 1 0 1.06 1.06L10 11.06l3.72 3.72a.75.75 0 1 0 1.06-1.06L11.06 10l3.72-3.72a.75.75 0 0 0-1.06-1.06L10 8.94 6.28 5.22Z"
						/>
					</svg>
				</button>
			</div>
		</div>
	</div>
{/if}
