declare module 'spark-md5' {
  /** Streaming hash instance: append can be called repeatedly and end() returns the final hex digest. */
  class SparkMD5ArrayBufferInstance {
    append(chunk: ArrayBuffer): this;
    end(raw?: boolean): string;
    reset(): this;
    getState(): unknown;
    setState(state: unknown): this;
  }

  type SparkMD5ArrayBufferCtor = {
    new (): SparkMD5ArrayBufferInstance;
    hash(data: ArrayBuffer): string;
  };

  const SparkMD5: {
    ArrayBuffer: SparkMD5ArrayBufferCtor;
  };

  export default SparkMD5;
}
