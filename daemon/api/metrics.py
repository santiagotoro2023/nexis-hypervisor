import asyncio
import json

from fastapi import APIRouter
from fastapi.responses import StreamingResponse

from core.metrics_collector import collect

router = APIRouter()


@router.get('/stream')
async def stream():
    async def generator():
        while True:
            try:
                data = collect()
                yield f'data: {json.dumps(data)}\n\n'
            except Exception as e:
                yield f'data: {{"error": "{e}"}}\n\n'
            await asyncio.sleep(2)

    return StreamingResponse(
        generator(),
        media_type='text/event-stream',
        headers={
            'Cache-Control': 'no-cache',
            'X-Accel-Buffering': 'no',
        },
    )
